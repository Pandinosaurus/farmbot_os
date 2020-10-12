defmodule FarmbotExt.Bootstrap.DropPasswordSupport do
  @moduledoc """
  Task to make sure the plaintext password is dropped form
  the sqlite database.
  """
  import FarmbotCore.Config, only: [update_config_value: 4, get_config_value: 3]
  require FarmbotCore.Logger

  def get_credentials do
    %{
      email: get_config_value(:string, "authorization", "email"),
      password: get_config_value(:string, "authorization", "password"),
      server: get_config_value(:string, "authorization", "server")
    }
  end

  def set_secret(secret) do
    # Drop the password from the database
    update_config_value(:string, "authorization", "secret", secret)
    update_config_value(:string, "authorization", "password", nil)
    FarmbotCore.Logger.debug(3, "Successfully encoded secret")
  end
end
