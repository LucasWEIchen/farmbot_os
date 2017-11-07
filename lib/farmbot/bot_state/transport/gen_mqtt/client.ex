defmodule Farmbot.BotState.Transport.GenMQTT.Client do
  @moduledoc "Underlying client for interfacing MQTT."
  use GenMQTT
  use Farmbot.Logger
  alias Farmbot.CeleryScript.AST

  @doc "Start a MQTT Client."
  def start_link(device, token, server) do
    GenMQTT.start_link(
      __MODULE__,
      {device, server},
      reconnect_timeout: 10000,
      username: device,
      password: token,
      timeout: 10000,
      host: server
    )
  end

  @doc "Push a bot state message."
  def push_bot_state(client, state) do
    GenMQTT.cast(client, {:bot_state, state})
  end

  @doc "Push a log message."
  def push_bot_log(client, log) do
    GenMQTT.cast(client, {:bot_log, log})
  end

  @doc "Emit an AST to the frontend."
  def emit(client, %AST{} = ast) do
    GenMQTT.cast(client, {:emit, ast})
  end

  def init({device, _server}) do
    {:ok, %{connected: false, device: device, cache: nil}}
  end

  def on_connect_error(:invalid_credentials, state) do
    msg = """
    Failed to authenticate with the message broker.
    This is likely a problem with your server/broker configuration.
    """

    Logger.error(1, msg)
    Farmbot.System.factory_reset(msg)
    {:ok, state}
  end

  def on_connect_error(reason, state) do
    Logger.error(2, "Failed to connect to mqtt: #{inspect(reason)}")
    {:ok, state}
  end

  def on_connect(state) do
    GenMQTT.subscribe(self(), [{bot_topic(state.device), 0}])
    GenMQTT.subscribe(self(), [{sync_topic(state.device), 0}])
    Logger.info(3, "Connected to real time services.")

    if state.cache do
      GenMQTT.publish(self(), status_topic(state.device), state.cache, 0, false)
    end

    {:ok, %{state | connected: true}}
  end

  def on_publish(["bot", _bot, "from_clients"], msg, state) do
    msg
    |> Poison.decode!()
    |> Farmbot.CeleryScript.AST.decode()
    |> elem(1)
    |> fn(ast) ->
      Logger.debug 3, "received #{inspect Farmbot.CeleryScript.AST.encode(ast) |> elem(1)}"
      ast
    end.()
    |> Farmbot.CeleryScript.execute()
    {:ok, state}
  end

  def on_publish(["bot", _, "sync", "Log", _], _, state) do
    {:ok, state}
  end

  def on_publish(["bot", _, "sync", kind, id], msg, state) do
    mod = Module.concat(["Farmbot", "Repo", kind])
    if Code.ensure_loaded?(mod) do
      body = struct(mod)
      sync_cmd = msg |> Poison.decode!(as: struct(Farmbot.Repo.SyncCmd, kind: mod, body: body, id: id))
      Farmbot.Repo.register_sync_cmd(sync_cmd)

      if Farmbot.System.ConfigStorage.get_config_value(:bool, "settings", "auto_sync") do
        Farmbot.Repo.flip()
      end
    else
      Logger.warn 2, "Unknown syncable: #{mod}: #{inspect Poison.decode!(msg)}"
    end
    {:ok, state}
  end

  def handle_cast(_, %{connected: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:bot_state, bs}, state) do
    json = Poison.encode!(bs)
    GenMQTT.publish(self(), status_topic(state.device), json, 0, false)
    {:noreply, %{state | cache: json}}
  end

  def handle_cast({:bot_log, log}, state) do
    json = Poison.encode!(log)
    GenMQTT.publish(self(), log_topic(state.device), json, 0, false)
    {:noreply, state}
  end

  def handle_cast({:emit, ast}, state) do
    # Logger.debug "Emitting #{inspect ast} | #{inspect AST.encode(ast) |> elem(1)}"
    {:ok, encoded_ast} = AST.encode(ast)
    json = Poison.encode!(encoded_ast)
    GenMQTT.publish(self(), frontend_topic(state.device), json, 0, false)
    {:noreply, state}
  end

  defp frontend_topic(bot), do: "bot/#{bot}/from_device"
  defp bot_topic(bot),      do: "bot/#{bot}/from_clients"
  defp sync_topic(bot),     do: "bot/#{bot}/sync/#"
  defp status_topic(bot),   do: "bot/#{bot}/status"
  defp log_topic(bot),      do: "bot/#{bot}/logs"
end
