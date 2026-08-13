defmodule PhoenixKitEmails.Test.StubEndpoint do
  @moduledoc """
  The smallest thing `Phoenix.LiveViewTest.render_component/3` accepts as an
  endpoint. This package ships no Endpoint of its own, which is why its
  settings sections had no render coverage at all — and why a component called
  with an attribute where a slot was required could take the whole settings
  page down with a green test suite.
  """

  def config(:cache_static_manifest_latest), do: %{}
  def config(:otp_app), do: :phoenix_kit_emails
  def config(_key), do: nil
  def config(_key, default), do: default
  def path(path), do: path
  def script_name, do: []
  def static_path(path), do: path
  def url, do: "http://localhost"
end
