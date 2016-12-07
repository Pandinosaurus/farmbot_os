defmodule Farmbot.Logger do
  @moduledoc """
    Logger backend for logging to the frontend and dumping to the API.
  """
  @rpc_transport Application.get_env(:json_rpc, :transport)
  use GenEvent
  alias RPC.Spec.Notification, as: Notification

  # I SUCK
  def handle_event(thing, Farmbot.Logger), do: handle_event(thing, build_state)
  # The example said ignore messages for other nodes, so im ignoring messages
  # for other nodes.
  def handle_event({_level, gl, {Logger, _, _, _}}, state)
    when node(gl) != node()
  do
    {:ok, state}
  end

  # Tehe
  def handle_event({l, f, {Logger, ">>" <> message, ts, meta}}, s) do
    device_name = Farmbot.Sync.device_name
    handle_event({l, f, {Logger, "#{device_name}"<> message, ts, meta}}, s)
  end

  # The logger event.
  def handle_event(
    {level, _, {Logger, message, timestamp, metadata}},
    {messages, posting?})
  do
    # if there is type key in the meta we need that to have priority
    relevent_meta = Keyword.take(metadata, [:type])
    type = parse_type(level, relevent_meta)

    # right now this will only ever be []
    # But eventually it will be sms, email, twitter, etc
    channels = parse_channels(Keyword.take(metadata, [:channels]))

    # BUG: should not be poling the bot for its position.
    pos = Farmbot.BotState.get_current_pos

    # take logger time stamp and spit out a unix timestamp for the javascripts.
    with {:ok, created_at} <- parse_created_at(timestamp) do
      thing =
        build_log(message, created_at, type, channels, pos)
      build_rpc(thing) |> @rpc_transport.emit
      dispatch({messages ++ [thing], posting?})
    end || dispatch({messages, posting?})
  end

  def handle_event(:flush, state) do
    IO.puts "YOU FORGOT TO FINISH THIS!!!@"
    # flush(state)
    {:ok, state}
  end

  # If the post succeeded, we clear the messages
  def handle_info(:post_success, {_, _}), do: dispatch { [], false}
  # If it did not succeed, keep the messages, and try again until it completes.
  def handle_info(:post_fail, {messages, _}), do: dispatch { messages, false}

  # Catch any stray send messages that we don't care about.
  def handle_info(_, state), do: dispatch state

  # This if mostly for the RPC request to get all logs but is handy in other use
  # Cases too.
  def handle_call(:dump, {messages, posting?}) do
    {:ok, messages, {messages, posting?}}
  end

  # Catch any stray calls.
  def handle_call(_, state), do: {:ok, :unhandled, state}

  @doc """
    Gets the current logs from the log buffer.
  """
  def get_logs, do: GenEvent.call(Logger, Farmbot.Logger, :dump)

  @doc """
    Dumps the current log buffer to the front end.
  """
  def dump, do: get_logs |> build_rpc_dump |> @rpc_transport.emit

  # Dont know if this can happen but just in case.
  defp dispatch(Farmbot.Logger), do: {:ok, build_state}

  # IF we are already posting messages to the api, no need to check the count.
  defp dispatch({messages, true}), do: {:ok, {messages, true}}
  # If we not already doing an HTTP Post to the api, check to see if we need to
  # (check if the count of messages is greater than 50)
  defp dispatch({messages, false}) do
    if Enum.count(messages) > 50 do
      do_post(messages, self())
      {:ok, {messages, true}}
    else
      {:ok, {messages, false}}
    end
  end

  # Posts an array of logs to the API.
  @spec do_post([log_message],pid) :: :ok
  defp do_post(m, pid) do
    case Poison.encode(m) do
      {:ok, messages} ->
        Farmbot.HTTP.post("/api/logs", messages)
        |> parse_resp(pid)
      _ ->
        IO.puts "error parsing: #{inspect m}"
    end
  end

  # Parses what the api sends back. Will only ever return :ok even if there was
  # an error.
  @spec parse_resp(HTTPotion.Response.t | HTTPotion.ErrorResponse.t, pid) :: :ok
  defp parse_resp(%HTTPotion.ErrorResponse{message: _m}, pid),
    do: send(pid, :post_fail)
  defp parse_resp(%HTTPotion.Response{status_code: 200}, pid),
    do: send(pid, :post_success)
  defp parse_resp(_error, pid),
    do: send(pid, :post_fail)

  @type rpc_log_type
    :: :success
     | :busy
     | :warn
     | :error
     | :info
     | :fun

  @type logger_level
    :: :info
     | :debug
     | :warn
     | :error

  @type channels :: :toast

  @type meta :: [] | [type: rpc_log_type]
  @type log_message
  :: %{message: String.t,
       channels: channels,
       created_at: integer,
       meta: %{
          type: rpc_log_type,
          x: integer,
          y: integer,
          z: integer }}

  # Translates Logger levels into Farmbot levels.
  # :info -> :info
  # :debug -> :info
  # :warn -> :warn
  # :error -> :error
  #
  # Also takes some meta.
  # Meta should take priority over
  # Logger Levels.
  @spec parse_type(logger_level, meta) :: rpc_log_type
  defp parse_type(:debug, []), do: :info
  defp parse_type(level, []), do: level
  defp parse_type(_level, [type: type]), do: type

  # can't jsonify tuples.
  defp parse_channels([channels: channels]), do: channels
  defp parse_channels(_), do: []

  # Couuld probably do this inline but wheres the fun in that. its a functional
  # language isn't it?
  # Takes Loggers time stamp and converts it into a unix timestamp.
  defp parse_created_at({{year, month, day}, {hour, minute, second, _}}) do
    dt = Timex.to_datetime({{year, month, day}, {hour, minute, second}})
    unix = dt |> Timex.to_unix
    {:ok, unix}
  end
  defp parse_created_at({_,_}), do: {:ok, :os.system_time}

  @spec build_log(String.t, number, rpc_log_type, [channels], [integer])
  :: log_message
  defp build_log(message, created_at, type, channels, [x,y,z]) do
    %{message: message,
      created_at: created_at,
      channels: channels,
      meta: %{
        type: type,
        x: x,
        y: y,
        z: z }}
  end

  defp build_rpc(msg) do
    case Poison.encode(
      %Notification{
        id: nil,
        method: "log_message",
        params: [msg]})
    do
      {:ok, m} -> m
      _ -> IO.puts "error parsing #{inspect msg}"
    end
  end

  # Takes a list of rpc log messages
  defp build_rpc_dump(rpc_logs)
  when is_list(rpc_logs) do
    case Poison.encode(
      %Notification{
        id: nil,
        method: "log_dump",
        params:  rpc_logs })
    do
      {:ok, m} -> m
      _ -> IO.puts "error parsing #{inspect rpc_logs}"
    end
  end

  @type posting? :: boolean
  @spec build_state :: {[log_message], posting?}
  defp build_state, do: {[], false}
end
