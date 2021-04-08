defmodule FarmbotCore.Firmware.GCodeDecoder do
  @moduledoc """
  """

  @response_codes %{
    "00" => :idle,
    "01" => :start,
    "02" => :ok,
    "03" => :error,
    "04" => :running,
    "05" => :axis_state_report,
    "06" => :calibration_state_report,
    "07" => :movement_retry,
    "08" => :echo,
    "09" => :invalidation,
    "11" => :complete_homing_x,
    "12" => :complete_homing_y,
    "13" => :complete_homing_z,
    "15" => :different_x_coordinate_than_given,
    "16" => :different_y_coordinate_than_given,
    "17" => :different_z_coordinate_than_given,
    "20" => :paramater_completion,
    "21" => :parameter_value_report,
    "23" => :report_updated_parameter_during_calibration,
    "41" => :pin_value_report,
    "71" => :x_axis_timeout,
    "72" => :y_axis_timeout,
    "73" => :z_axis_timeout,
    "81" => :end_stops_report,
    "82" => :current_position,
    "83" => :software_version,
    "84" => :encoder_position_scaled,
    "85" => :encoder_position_raw,
    "87" => :emergency_lock,
    "88" => :not_configured,
    "89" => :missed_steps_per_500_report,
    "99" => :debug_message
  }

  @params %{
    "A" => :x_speed,
    "B" => :y_speed,
    "C" => :z_speed,
    "E" => :element,
    "M" => :mode,
    "N" => :number,
    "P" => :pin_number,
    "Q" => :queue,
    "T" => :seconds,
    "V" => :value,
    "W" => :value2,
    "X" => :x,
    "XA" => :z_endstop_a,
    "XB" => :z_endstop_b,
    "Y" => :y,
    "YA" => :z_endstop_a,
    "YB" => :z_endstop_b,
    "Z" => :z,
    "ZA" => :z_endstop_a,
    "ZB" => :z_endstop_b
  }

  def run({parser, messages}) do
    next_messages =
      messages
      |> Enum.map(&validate_message/1)
      |> Enum.map(&preprocess/1)

    {parser, next_messages}
  end

  defp validate_message("R99" <> _ = m), do: m
  defp validate_message("R" <> _ = m), do: m

  defp validate_message(message) do
    actual = inspect(message)
    raise "Expect inbound GCode to begin with `R`. Got: #{actual}"
  end

  defp preprocess("R99" <> rest) do
    {response_code("99"), String.trim(rest)}
  end

  defp preprocess("R" <> <<code::binary-size(2)>> <> rest) do
    {response_code(code), parameterize(rest)}
  end

  defp response_code(code), do: Map.fetch!(@response_codes, code)
  defp parameter_code(code), do: Map.fetch!(@params, code)

  defp parameterize(string) do
    string
    |> String.trim()
    |> String.split(" ")
    |> Enum.map(fn pair ->
      [number] = Regex.run(~r/\d+\.?\d?+/, pair)
      [code] = Regex.run(~r/\D{1,2}/, pair)
      {float, _} = Float.parse(number)
      {parameter_code(code), float}
    end)
    |> Enum.reduce(%{}, fn {key, val}, acc -> Map.put(acc, key, val) end)
  end
end