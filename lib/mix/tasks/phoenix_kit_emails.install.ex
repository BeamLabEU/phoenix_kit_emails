defmodule Mix.Tasks.PhoenixKitEmails.Install do
  @moduledoc """
  Installs PhoenixKit Emails module into parent application.

  Adds the required `@source` directive to your CSS file so Tailwind CSS
  can discover classes used by the emails module's templates.

  ## Usage

      mix phoenix_kit_emails.install

  ## What it does

  1. Finds your `assets/css/app.css` file
  2. Adds `@source "../../deps/phoenix_kit_emails";` after existing `@source` lines
  3. Prints next steps for AWS SES configuration

  This task is idempotent — safe to run multiple times.
  """

  use Mix.Task

  @shortdoc "Install PhoenixKit Emails module"

  @source_directive ~s(@source "../../deps/phoenix_kit_emails";)
  @source_pattern ~r/@source\s+["'][^"']*phoenix_kit_emails["']/

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("Installing PhoenixKit Emails...")

    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    case find_app_css(css_paths) do
      {:ok, css_path} ->
        add_css_source(css_path)

      {:error, :not_found} ->
        print_manual_css_instructions()
    end

    print_next_steps()
  end

  defp find_app_css(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp add_css_source(css_path) do
    content = File.read!(css_path)

    if String.match?(content, @source_pattern) do
      Mix.shell().info("  ✓ CSS source already configured in #{css_path}")
    else
      updated = insert_source_directive(content)
      File.write!(css_path, updated)
      Mix.shell().info("  ✓ Added @source directive to #{css_path}")
    end
  end

  defp insert_source_directive(content) do
    lines = String.split(content, "\n")

    last_source_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {line, _index} ->
        String.match?(line, ~r/^@source\s+/)
      end)

    case last_source_index do
      {_line, index} ->
        {before, after_lines} = Enum.split(lines, index + 1)
        Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

      nil ->
        import_index =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, _} -> String.match?(line, ~r/^@import\s+/) end)

        case import_index do
          {_line, index} ->
            {before, after_lines} = Enum.split(lines, index + 1)
            Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

          nil ->
            @source_directive <> "\n" <> content
        end
    end
  end

  defp print_manual_css_instructions do
    Mix.shell().info("""

      ⚠  Could not find app.css. Please manually add this line:

         #{@source_directive}

      Common locations: assets/css/app.css
    """)
  end

  defp print_next_steps do
    Mix.shell().info("""

    PhoenixKit Emails installed successfully!

    Next steps:
    1. Run `mix deps.get` if you haven't already
    2. Add Oban queues to config/config.exs:
       queues: [emails: 50, sqs_polling: 1]
    3. Configure AWS SES credentials in Settings UI or config/prod.exs
    4. Run `mix phoenix_kit.update` to apply email migrations
    5. Enable the Emails module in Admin → Modules
    """)
  end
end
