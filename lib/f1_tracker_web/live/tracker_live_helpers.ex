defmodule F1TrackerWeb.TrackerLiveHelpers do
  @moduledoc "Helper functions imported into TrackerLive template"

  def race_control_class(%{"flag" => "RED"}), do: "bg-red-900/50 text-red-300"
  def race_control_class(%{"flag" => "YELLOW"}), do: "bg-yellow-900/50 text-yellow-300"
  def race_control_class(%{"flag" => "GREEN"}), do: "bg-green-900/50 text-green-300"
  def race_control_class(%{"category" => "SafetyCar"}), do: "bg-orange-900/50 text-orange-300"
  def race_control_class(_), do: "bg-gray-800 text-gray-300"
end
