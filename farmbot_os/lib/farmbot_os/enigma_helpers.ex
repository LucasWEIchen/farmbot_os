defmodule FarmbotOS.EnigmaHelpers do
  def firmware_missing(package) when package in ~w(arduino farmduino farmduino_k14) do
    ref =
      %{
        kind: :rpc_request,
        args: %{label: "findme"},
        body: [%{kind: :flash_firmware, args: %{package: "arduino"}}]
      }
      |> FarmbotCeleryScript.AST.decode()
      |> FarmbotCeleryScript.Scheduler.schedule()
  end
end
