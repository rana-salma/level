defmodule Level.Loaders do
  @moduledoc """
  Sources for Dataloader.
  """

  alias Level.Loaders.Database

  # Suppress dialyzer warnings about dataloader functions
  @dialyzer {:nowarn_function, database_source: 1}

  def database_source(params) do
    Database.source(params)
  end
end
