defmodule FarmbotExt.AMQP.AutoSyncChannel do
  @moduledoc """
  This module provides an AMQP channel for
  auto-sync messages from the FarmBot API.
  SEE:
    https://developer.farm.bot/docs/realtime-updates-auto-sync#section-example-auto-sync-subscriptions
  """
  use GenServer
  use AMQP

  alias FarmbotCore.{Asset, BotState, JSON}
  alias FarmbotExt.AMQP.ConnectionWorker
  alias FarmbotExt.API.{EagerLoader, Preloader}

  require Logger
  require FarmbotCore.Logger

  @cache_kinds ~w(
    Device
    FbosConfig
    FirmwareConfig
    FarmwareEnv
    FarmwareInstallation
  )

  defstruct [:conn, :chan, :jwt, :preloaded]
  alias __MODULE__, as: State

  @doc "Gets the current status of an auto_sync connection"
  def network_status(server \\ __MODULE__) do
    GenServer.call(server, :network_status)
  end

  @doc false
  def start_link(args, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def init(args) do
    Process.flag(:sensitive, true)
    jwt = Keyword.fetch!(args, :jwt)
    {:ok, %State{conn: nil, chan: nil, jwt: jwt, preloaded: false}, {:continue, :preload}}
  end

  def terminate(reason, state) do
    FarmbotCore.Logger.error(1, "Disconnected from AutoSync channel: #{inspect(reason)}")
    # If a channel was still open, close it.
    if state.chan, do: ConnectionWorker.close_channel(state.chan)
  end

  def handle_continue(:preload, state) do
    :ok = Preloader.preload_all()
    next_state = %{state | preloaded: true}
    :ok = BotState.set_sync_status("synced")
    {:noreply, next_state, {:continue, :connect}}
  end

  def handle_continue(:connect, state) do
    result = ConnectionWorker.maybe_connect(state.jwt.bot)
    compute_reply_from_amqp_state(state, result)
  end

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, _}, state) do
    {:noreply, state}
  end

  # Sent by the broker when the consumer is
  # unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, _}, state) do
    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, _}, state) do
    {:noreply, state}
  end

  def handle_info({:basic_deliver, payload, %{routing_key: key}}, state) do
    chan = state.chan
    data = JSON.decode!(payload)
    device = state.jwt.bot
    label = data["args"]["label"]
    body = data["body"]

    case String.split(key, ".") do
      ["bot", ^device, "sync", asset_kind, id_str] ->
        id = data["id"] || String.to_integer(id_str)
        handle_asset(asset_kind, id, body)

      _ ->
        Logger.info("ignoring route: #{key}")
    end

    :ok = ConnectionWorker.rpc_reply(chan, device, label)
    {:noreply, state}
  end

  def handle_call(:network_status, _, state) do
    reply = %{conn: state.conn, chan: state.chan, preloaded: state.preloaded}

    {:reply, reply, state}
  end

  def handle_asset(asset_kind, id, params) do
    if Asset.Query.auto_sync?() do
      :ok = BotState.set_sync_status("syncing")
      Asset.Command.update(asset_kind, params, id)
      :ok = BotState.set_sync_status("synced")
    else
      cache_sync(asset_kind, params, id)
    end
  end

  def cache_sync(kind, params, id) when kind in @cache_kinds do
    :ok = BotState.set_sync_status("syncing")
    :ok = Asset.Command.update(kind, params, id)
    :ok = BotState.set_sync_status("synced")
  end

  def cache_sync(asset_kind, params, id) do
    Logger.info("Autocaching sync #{asset_kind} #{id} #{inspect(params)}")
    changeset = Asset.Command.new_changeset(asset_kind, id, params)
    :ok = EagerLoader.cache(changeset)
    :ok = BotState.set_sync_status("sync_now")
  end

  defp compute_reply_from_amqp_state(state, %{conn: conn, chan: chan}) do
    {:noreply, %{state | conn: conn, chan: chan}}
  end

  defp compute_reply_from_amqp_state(state, error) do
    # Run error warning if error not nil
    if error,
      do: FarmbotCore.Logger.error(1, "Failed to connect to AutoSync channel: #{inspect(error)}")

    {:noreply, %{state | conn: nil, chan: nil}}
  end
end
