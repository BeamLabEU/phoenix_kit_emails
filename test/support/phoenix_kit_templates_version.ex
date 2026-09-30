defmodule PhoenixKitEmails.TestSupport.PhoenixKitTemplatesVersion do
  @moduledoc """
  Test-only helper to exercise `TemplateExport.default_raw_html_support?/0`
  against the real `Application` registry instead of only the version this
  repo's `mix.lock` happens to pin right now. Every test that calls into here
  must live in an `async: false` module: the version it patches is process-
  global for the whole VM, not scoped to one test.
  """

  @app :phoenix_kit_templates

  @doc """
  Runs `fun` with `#{inspect(@app)}` loaded at `vsn` (a version string or
  charlist), restoring its real spec afterward even if `fun` raises.
  """
  @spec with_version(String.t() | charlist(), (-> result)) :: result when result: var
  def with_version(vsn, fun) do
    original_spec = Application.spec(@app) || raise "#{inspect(@app)} is not loaded"

    try do
      :ok = patch(original_spec, to_charlist(vsn))
      fun.()
    after
      restore(original_spec)
    end
  end

  @doc """
  Runs `fun` with `#{inspect(@app)}` fully unloaded (`Application.spec/1`
  returns `nil`), restoring it afterward even if `fun` raises — for testing
  `default_raw_html_support?/0`'s own `Application.load/1` fallback.
  """
  @spec unloaded((-> result)) :: result when result: var
  def unloaded(fun) do
    original_spec = Application.spec(@app) || raise "#{inspect(@app)} is not loaded"

    try do
      _ = Application.stop(@app)
      :ok = Application.unload(@app)
      fun.()
    after
      restore(original_spec)
    end
  end

  defp patch(spec, vsn) do
    _ = Application.stop(@app)
    :ok = Application.unload(@app)
    :application.load({:application, @app, Keyword.put(spec, :vsn, vsn)})
  end

  defp restore(spec) do
    _ = Application.stop(@app)
    _ = Application.unload(@app)
    :ok = :application.load({:application, @app, spec})
    _ = Application.ensure_all_started(@app)
  end
end
