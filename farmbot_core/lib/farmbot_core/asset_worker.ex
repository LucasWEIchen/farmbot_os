defprotocol FarmbotCore.AssetWorker do
  # A process that represents a single database row.

  @doc "List of relational resources that need to be preloaded."
  def preload(asset)

  @doc "GenServer childspec callback."
  def start_link(asset, args \\ [])
end
