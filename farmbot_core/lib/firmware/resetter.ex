defmodule FarmbotCore.Firmware.Resetter do
  if Code.ensure_compiled(Circuits.GPIO) do
    @gpio Circuits.GPIO
  else
    @gpio nil
  end

  @waits [650, 875, 1100, 1300, 1500]

  alias FarmbotCore.Asset
  alias FarmbotCore.Project

  require FarmbotCore.Logger

  def reset(package \\ nil) do
    pkg = package || Asset.fbos_config(:firmware_hardware)
    FarmbotCore.Logger.debug(3, "Attempting to retrieve #{pkg} reset function.")
    {:ok, fun} = find_reset_fun(Project.target(), pkg)
    fun.()
  end

  def find_reset_run(:rpi, "none"), do: use_special_fn(@gpio)
  def find_reset_fun(:rpi, "express_k10"), do: use_special_fn(@gpio)
  def find_reset_fun(_, _), do: use_default()

  def use_default() do
    FarmbotCore.Logger.debug(3, "Using default reset function")
    {:ok, fn -> :ok end}
  end

  defp use_special_fn(nil), do: use_default()

  defp use_special_fn(_) do
    msg = "Using special express reset function"
    FarmbotCore.Logger.debug(3, msg)
    {:ok, fn -> maybe_special_fn(@gpio) end}
  end

  defp maybe_special_fn(gpio_module) do
    try do
      wait = Enum.random(@waits)
      FarmbotCore.Logger.debug(3, "Begin MCU reset (#{inspect(wait)} ms)")
      {:ok, gpio} = gpio_module.open(19, :output)
      :ok = gpio_module.write(gpio, 0)
      :ok = gpio_module.write(gpio, 1)
      Process.sleep(wait)
      :ok = gpio_module.write(gpio, 0)
      gpio_module.close(gpio)
      FarmbotCore.Logger.debug(3, "Finish MCU Reset")
      :ok
    rescue
      ex ->
        message = Exception.message(ex)
        msg = "Express reset failed #{message}"
        FarmbotCore.Logger.error(3, msg)
        {:error, msg}
    end
  end
end