defmodule PhoenixKit.Modules.Emails.Archiver do
  @moduledoc """
  Archive and compress old email tracking data for optimal storage.

  Provides comprehensive data lifecycle management for email tracking:

  - **Body Compression** - Compress full email bodies after configurable time
  - **S3 Archival** - Move old logs to S3 cold storage  
  - **Sampling Optimization** - Apply sampling to reduce storage load
  - **Cleanup Integration** - Work with cleanup tasks for complete lifecycle
  - **Performance Optimization** - Batch operations for large datasets

  ## Storage Optimization Strategy

  1. **Recent Data** (0-7 days): Full storage with all fields
  2. **Medium Data** (7-30 days): Compress body_full, keep metadata
  3. **Old Data** (30-90 days): Archive to S3, keep local summary
  4. **Ancient Data** (90+ days): Delete after S3 confirmation

  ## Settings Integration

  All archival settings stored in phoenix_kit_settings:

  - `email_compress_body` - Days before compressing bodies (default: 30)
  - `email_archive_to_s3` - Enable S3 archival (default: false)
  - `email_s3_bucket` - S3 bucket name
  - `email_sampling_rate` - Percentage to fully log (default: 100)
  - `email_retention_days` - Total retention before deletion (default: 90)

  ## Usage Examples

      # Compress bodies older than 30 days
      {compressed_count, size_saved} = PhoenixKit.Modules.Emails.Archiver.compress_old_bodies(30)

      # Archive to S3 with automatic cleanup
      {:ok, archived_count} = PhoenixKit.Modules.Emails.Archiver.archive_to_s3(90, 
        bucket: "my-email-archive",
        prefix: "email-logs/2025/"
      )

      # Apply sampling to reduce future storage
      sampled_email = PhoenixKit.Modules.Emails.Archiver.apply_sampling_rate(email)

      # Get storage statistics
      stats = PhoenixKit.Modules.Emails.Archiver.get_storage_stats()
      # => %{total_logs: 50000, compressed: 15000, archived: 10000, size_mb: 2341}

  ## S3 Integration

  Supports multiple S3-compatible storage providers:
  - Amazon S3
  - DigitalOcean Spaces  
  - Google Cloud Storage
  - MinIO
  - Any S3-compatible service

  ## Compression Algorithm

  Uses gzip compression for email bodies with fallback strategies:

  1. **Gzip** - Primary compression for text content
  2. **Preview Only** - Keep only first 500 chars for very old data
  3. **Metadata Only** - Keep only delivery status and timestamps

  ## Batch Processing

  All operations are designed for efficiency:
  - Process in configurable batch sizes (default: 1000)
  - Progress tracking for long operations
  - Automatic retry on transient failures
  - Memory-efficient streaming for large datasets
  """

  require Logger
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.{Event, Log}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  import Ecto.Query

  ## --- Body Compression ---

  @doc """
  Compress email bodies older than specified days.

  Returns `{compressed_count, size_saved_bytes}`.

  ## Options

  - `:batch_size` - Process in batches (default: 1000)
  - `:dry_run` - Show what would be compressed without doing it
  - `:preserve_errors` - Don't compress emails with errors/bounces

  ## Examples

      # Compress bodies older than 30 days
      {count, saved} = Archiver.compress_old_bodies(30)
      # => {1523, 45231040}

      # Dry run to see impact
      {count, estimated_saved} = Archiver.compress_old_bodies(30, dry_run: true)
  """
  def compress_old_bodies(days_old \\ nil, opts \\ []) do
    days_old = days_old || get_compress_days()
    batch_size = Keyword.get(opts, :batch_size, 1000)
    dry_run = Keyword.get(opts, :dry_run, false)
    preserve_errors = Keyword.get(opts, :preserve_errors, true)

    Logger.info("Starting body compression for emails older than #{days_old} days")

    cutoff_date = DateTime.add(UtilsDate.utc_now(), -days_old * 86_400)

    query = build_compression_query(cutoff_date, preserve_errors)

    if dry_run do
      {count, estimated_size} = estimate_compression_savings(query)
      Logger.info("Would compress #{count} email bodies, saving ~#{format_bytes(estimated_size)}")
      {count, estimated_size}
    else
      process_compression_batches(query, batch_size)
    end
  end

  @doc """
  Apply sampling rate to email for storage optimization.

  Returns modified email with reduced storage footprint for non-critical emails.

  ## Sampling Strategy

  - **Always Full**: Error emails, bounces, complaints  
  - **Always Full**: Transactional emails (password resets, etc.)
  - **Sampling Applied**: Marketing emails, newsletters
  - **Metadata Only**: Bulk emails when over limit

  ## Examples

      # Apply system sampling rate
      email = Archiver.apply_sampling_rate(original_email)

      # Force specific sampling
      email = Archiver.apply_sampling_rate(original_email, force_rate: 50)
  """
  def apply_sampling_rate(email_attrs, opts \\ []) do
    sampling_rate = Keyword.get(opts, :force_rate) || get_sampling_rate()

    # Always store critical emails fully
    if critical_email?(email_attrs) do
      email_attrs
    else
      random_value = :rand.uniform(100)

      if random_value <= sampling_rate do
        # Store fully
        email_attrs
      else
        # Store with reduced data
        apply_reduced_storage(email_attrs)
      end
    end
  end

  ## --- S3 Archival ---

  @doc """
  Archive old emails to S3 storage.

  Returns `{:ok, archived_count}` on success or `{:error, reason}` on failure.

  ## Options

  - `:bucket` - S3 bucket name (required)
  - `:prefix` - S3 object key prefix
  - `:batch_size` - Process in batches (default: 500) 
  - `:format` - Archive format: :json (default) or :csv
  - `:delete_after_archive` - Delete from DB after successful archive
  - `:include_events` - Include email events in archive

  ## Examples

      # Basic S3 archival
      {:ok, count} = Archiver.archive_to_s3(90,
        bucket: "email-archive",
        prefix: "logs/2025/"
      )

      # Archive with events and cleanup
      {:ok, count} = Archiver.archive_to_s3(90,
        bucket: "email-archive", 
        include_events: true,
        delete_after_archive: true
      )
  """
  def archive_to_s3(days_old, opts \\ []) do
    if s3_archival_enabled?() do
      bucket = present_string(Keyword.get(opts, :bucket)) || get_s3_bucket()
      prefix = Keyword.get(opts, :prefix, "email-logs/")
      batch_size = Keyword.get(opts, :batch_size, 500)
      format = Keyword.get(opts, :format, :json)
      delete_after = Keyword.get(opts, :delete_after_archive, false)
      include_events = Keyword.get(opts, :include_events, true)

      if bucket do
        do_s3_archival(days_old, bucket, prefix, batch_size, format, delete_after, include_events)
      else
        {:error, :no_bucket_configured}
      end
    else
      {:error, :s3_not_configured}
    end
  end

  defp do_s3_archival(days_old, bucket, prefix, batch_size, format, delete_after, include_events) do
    Logger.info("Starting S3 archival for emails older than #{days_old} days")

    cutoff_date = DateTime.add(UtilsDate.utc_now(), -days_old * 86_400)

    case process_s3_archival(
           cutoff_date,
           bucket,
           prefix,
           batch_size,
           format,
           include_events,
           delete_after
         ) do
      {:ok, archived_count} ->
        Logger.info("Successfully archived #{archived_count} emails to S3")
        {:ok, archived_count}

      {:error, reason} ->
        Logger.error("S3 archival failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  ## --- Storage Statistics ---

  @doc """
  Get comprehensive storage statistics.

  ## Examples

      iex> Archiver.get_storage_stats()
      %{
        total_logs: 125000,
        total_events: 450000,
        compressed_bodies: 45000,
        archived_logs: 15000,
        storage_size_mb: 2341,
        oldest_log: ~U[2024-01-15 10:30:00Z],
        compression_ratio: 0.65,
        s3_archived_size_mb: 890
      }
  """
  def get_storage_stats do
    %{
      total_logs: count_total_logs(),
      total_events: count_total_events(),
      compressed_bodies: count_compressed_bodies(),
      archived_logs: count_archived_logs(),
      storage_size_mb: calculate_storage_size_mb(),
      oldest_log: get_oldest_log_date(),
      compression_ratio: calculate_compression_ratio(),
      s3_archived_size_mb: get_s3_archived_size()
    }
  end

  @doc """
  Get detailed storage breakdown by time periods.

  ## Examples

      iex> Archiver.get_storage_breakdown()
      %{
        last_7_days: %{logs: 5000, size_mb: 145, compressed: false},
        last_30_days: %{logs: 15000, size_mb: 420, compressed: 8000},
        last_90_days: %{logs: 35000, size_mb: 980, compressed: 25000},
        older: %{logs: 70000, size_mb: 1200, archived: 45000}
      }
  """
  def get_storage_breakdown do
    now = UtilsDate.utc_now()

    %{
      last_7_days: get_period_stats(DateTime.add(now, -7 * 86_400), now),
      last_30_days: get_period_stats(DateTime.add(now, -30 * 86_400), now),
      last_90_days: get_period_stats(DateTime.add(now, -90 * 86_400), now),
      older: get_period_stats(~U[1970-01-01 00:00:00Z], DateTime.add(now, -90 * 86_400))
    }
  end

  ## --- Configuration Helpers ---

  defp get_compress_days do
    Settings.get_integer_setting("email_compress_body", 30)
  end

  defp get_sampling_rate do
    Settings.get_integer_setting("email_sampling_rate", 100)
  end

  defp s3_archival_enabled? do
    Settings.get_boolean_setting("email_archive_to_s3", false)
  end

  # An empty setting is "unset", not a bucket named "". Without this the
  # `if bucket do` guard above passes on a blank string and the upload is
  # attempted against no bucket at all.
  defp get_s3_bucket, do: setting_or_nil("email_s3_bucket")

  defp setting_or_nil(key) do
    present_string(Settings.get_setting(key))
  end

  # Empty string is truthy in Elixir, so `if bucket do` and `||` both treat
  # `""` as a real bucket. An explicit `bucket: ""` opt used to skip the
  # settings fallback and then pass the same blank guard.
  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  ## --- Query Builders ---

  defp build_compression_query(cutoff_date, preserve_errors) do
    query =
      from(l in Log,
        where: l.sent_at < ^cutoff_date,
        where: not is_nil(l.body_full),
        where: l.body_full != ""
      )

    if preserve_errors do
      query
      |> where([l], l.status not in ["bounced", "failed", "complained"])
    else
      query
    end
  end

  defp build_archival_query(cutoff_date) do
    from(l in Log,
      where: l.sent_at < ^cutoff_date,
      # Skip what a previous run already shipped. This is what makes the job
      # safe to re-run: without it every pass re-uploads the same rows unless
      # the run also deletes them.
      where: is_nil(l.archived_at),
      order_by: [asc: l.sent_at]
    )
  end

  ## --- Compression Implementation ---

  defp estimate_compression_savings(query) do
    stats_query =
      from(l in query,
        select: {count(l.uuid), sum(fragment("LENGTH(?)", l.body_full))}
      )

    case repo().one(stats_query) do
      {count, total_size} when not is_nil(total_size) ->
        # Estimate 60% compression ratio for email bodies
        estimated_savings = trunc(total_size * 0.6)
        {count || 0, estimated_savings}

      _ ->
        {0, 0}
    end
  end

  defp process_compression_batches(query, batch_size) do
    query
    |> stream_in_batches(batch_size, fn batch ->
      {batch_compressed, batch_saved} = compress_batch(batch)
      {batch_compressed, batch_saved}
    end)
    |> Enum.reduce({0, 0}, fn {count, saved}, {total_count, total_saved} ->
      {total_count + count, total_saved + saved}
    end)
  rescue
    # Mirror process_s3_archival's resilience: a raised exception inside the
    # streaming transaction (the whole run rolls back atomically) must not crash
    # the background compaction job. Report zero progress for this run.
    error ->
      Logger.error("Email archiver: body compression run failed: #{Exception.message(error)}")
      {0, 0}
  end

  defp compress_batch(email_logs) do
    Enum.reduce(email_logs, {0, 0}, fn log, {count, saved} ->
      case compress_email_body(log) do
        {:ok, size_saved} -> {count + 1, saved + size_saved}
        {:error, _} -> {count, saved}
      end
    end)
  end

  defp compress_email_body(%Log{} = log) do
    if log.body_full && String.length(log.body_full) > 100 do
      original_size = byte_size(log.body_full)

      # Compress with gzip
      compressed_data = :zlib.gzip(log.body_full)
      compressed_size = byte_size(compressed_data)

      # Only compress if we save significant space
      if compressed_size < original_size * 0.8 do
        case repo().update(
               Log.changeset(log, %{
                 body_full: Base.encode64(compressed_data)
               })
             ) do
          {:ok, _} -> {:ok, original_size - compressed_size}
          {:error, changeset} -> {:error, changeset}
        end
      else
        # Compression not worth it, just keep preview
        case repo().update(
               Log.changeset(log, %{
                 body_full: nil,
                 body_preview: String.slice(log.body_full, 0, 500)
               })
             ) do
          {:ok, _} -> {:ok, original_size}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:ok, 0}
    end
  end

  ## --- S3 Implementation ---

  # Pages on the `archived_at` stamp instead of holding a cursor. `Repo.stream`
  # requires an enclosing transaction, and every upload used to happen inside
  # it: a run over a large backlog kept one connection — and one transaction
  # snapshot — open for its whole duration, which is precisely what stops
  # autovacuum from reclaiming anything on the busiest table in the schema.
  # Now each batch is its own short transaction-free unit: select the next N
  # unshipped rows, upload, stamp. The stamp is what advances the cursor, so
  # there is nothing to hold open between batches.
  #
  # A batch that fails to upload stays unstamped, which would make the next
  # `next_batch/2` return the same rows forever — so a failed batch stops the
  # run rather than spinning on it. Whatever was already stamped stays
  # archived, and the next tick resumes from there.
  defp process_s3_archival(
         cutoff_date,
         bucket,
         prefix,
         batch_size,
         format,
         include_events,
         delete_after
       ) do
    archive_loop(cutoff_date, bucket, prefix, batch_size, format, include_events, delete_after, 0)
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Same reason `archive_batch_to_s3/6` carries one: dialyzer resolves
  # `ExAws.request/2` to its error branch only (the module is outside the PLT),
  # so it concludes a batch can never report a non-zero count and calls the
  # success clause here unreachable. It is reachable in every run that uploads
  # anything.
  @dialyzer {:nowarn_function, archive_loop: 8}
  defp archive_loop(
         cutoff,
         bucket,
         prefix,
         batch_size,
         format,
         include_events,
         delete_after,
         done
       ) do
    case next_batch(cutoff, batch_size) do
      [] ->
        {:ok, done}

      batch ->
        case archive_batch_to_s3(batch, bucket, prefix, format, include_events, delete_after) do
          0 ->
            Logger.error("S3 archival stopped after #{done} logs: a batch failed to upload")

            {:error, :upload_failed}

          count ->
            archive_loop(
              cutoff,
              bucket,
              prefix,
              batch_size,
              format,
              include_events,
              delete_after,
              done + count
            )
        end
    end
  end

  defp next_batch(cutoff, batch_size) do
    cutoff
    |> build_archival_query()
    |> limit(^batch_size)
    |> repo().all()
  end

  @dialyzer {:nowarn_function, archive_batch_to_s3: 6}
  defp archive_batch_to_s3(logs, bucket, prefix, format, include_events, delete_after) do
    now = UtilsDate.utc_now()
    batch_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    archive_data = prepare_archive_data(logs, format, include_events)
    s3_key = object_key(prefix, now, format, batch_id)

    case upload_to_s3(bucket, s3_key, archive_data, format) do
      {:ok, _message} ->
        # Record BEFORE deleting, and record even when not deleting. The old
        # code left no trace of a successful upload unless the rows were
        # destroyed, so a run configured to keep its data re-uploaded the same
        # messages on every pass, and a run that did delete could not tell a
        # crash-after-upload from a crash-before.
        Log.mark_archived(Enum.map(logs, & &1.uuid), s3_key, now)

        if delete_after do
          delete_archived_logs(logs)
        end

        length(logs)

      {:error, reason} ->
        Logger.error("Failed to archive batch to S3: #{inspect(reason)}")
        0
    end
  end

  # `Log` derives `JSON.Encoder` with `except: [:__meta__, :user, :events]`, so
  # the old `Map.put(log, :events, events)` put the events on a key the encoder
  # is told to skip: every archive written with `include_events: true` silently
  # contained no events at all. They go BESIDE the log now, not inside it.
  #
  # One query for the whole batch rather than one per log — the per-log version
  # was 500 round trips per batch.
  @doc false
  # Public only so the encoding can be asserted without a network. Everything
  # from here to `ExAws.request/2` is pure, and it is where the two silent
  # data bugs lived (events dropped by the encoder, a body mislabelled as
  # gzip) -- exactly the part a test can pin.
  def prepare_archive_data(logs, format, include_events)

  def prepare_archive_data(logs, :json, include_events) do
    events_by_log = if include_events, do: events_for(logs), else: %{}

    records =
      Enum.map(logs, fn log ->
        %{log: log, events: Map.get(events_by_log, log.uuid, [])}
      end)

    JSON.encode!(%{
      exported_at: UtilsDate.utc_now(),
      total_records: length(logs),
      includes_events: include_events,
      records: records
    })
  end

  def prepare_archive_data(logs, :csv, _include_events) do
    # CSV format implementation
    header = "uuid,message_id,to,from,subject,status,sent_at,delivered_at\n"

    rows =
      logs
      |> Enum.map_join("\n", fn log ->
        [
          log.uuid,
          log.message_id,
          log.to,
          log.from,
          log.subject,
          log.status,
          log.sent_at,
          log.delivered_at
        ]
        |> Enum.map_join(",", &csv_escape/1)
      end)

    header <> rows
  end

  defp events_for([]), do: %{}

  defp events_for(logs) do
    uuids = Enum.map(logs, & &1.uuid)

    from(e in Event, where: e.email_log_uuid in ^uuids)
    |> repo().all()
    |> Enum.group_by(& &1.email_log_uuid)
  end

  @spec upload_to_s3(String.t(), String.t(), binary(), :json | :csv) ::
          {:ok, String.t()} | {:error, String.t()}
  defp upload_to_s3(bucket, key, data, format) do
    # The headers used to claim `application/gzip` + `content-encoding: gzip`
    # over a plain JSON or CSV body. Every S3 client that honours them — the
    # console preview, `aws s3 cp`, anything using the SDK's transparent
    # decoding — then tried to gunzip text and failed, which would have turned
    # the archive into an unreadable blob at exactly the moment someone needed
    # to read it. The body is not compressed, so the headers now say so.
    case ExAws.S3.put_object(bucket, key, data,
           content_type: content_type(format),
           metadata: %{
             "archived-by" => "phoenix_kit",
             "archived-at" => DateTime.to_iso8601(UtilsDate.utc_now())
           }
         )
         |> ExAws.request(s3_request_config()) do
      {:ok, _result} ->
        Logger.info("Successfully uploaded archive to S3: s3://#{bucket}/#{key}")
        {:ok, "Successfully archived to S3: #{key}"}

      {:error, {:http_error, 404, _}} ->
        Logger.error("S3 bucket not found: #{bucket}")
        {:error, "S3 bucket not found. Please ensure bucket '#{bucket}' exists."}

      {:error, {:http_error, 403, _}} ->
        Logger.error("S3 access denied for bucket: #{bucket}")
        {:error, "Access denied to S3 bucket. Check IAM permissions."}

      {:error, reason} ->
        Logger.error("Failed to upload to S3: #{inspect(reason)}")
        {:error, "S3 upload failed: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("S3 upload exception: #{inspect(error)}")
      {:error, "S3 upload exception: #{Exception.message(error)}"}
  end

  # `YYYY/MM/DD/HHMMSS`. The key used to embed a full ISO-8601 timestamp, which
  # puts colons in the object name: legal in S3, but they need escaping in URLs
  # and quoting in every shell that touches them, and they would have been in
  # the name of every archive ever written. A date hierarchy also makes the
  # bucket browsable and lets a lifecycle rule target a prefix by age.
  #
  # `object_path/1` is the date half; `object_key/4` is the name actually
  # uploaded. They were split so the hierarchy could be asserted without a
  # network — and then the upload path kept calling `DateTime.to_iso8601/1`.
  # Both are public `@doc false` so a test can pin the full name, not just
  # the unused helper.
  @doc false
  def object_path(%DateTime{} = at) do
    "#{at.year}/#{pad(at.month)}/#{pad(at.day)}/#{pad(at.hour)}#{pad(at.minute)}#{pad(at.second)}"
  end

  @doc false
  def object_key(prefix, %DateTime{} = at, format, batch_id)
      when is_binary(prefix) and is_binary(batch_id) do
    "#{prefix}#{object_path(at)}-#{batch_id}.#{format}"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc false
  def content_type(:csv), do: "text/csv"
  def content_type(_), do: "application/json"

  # Credentials for the upload. AWS keys moved to `PhoenixKit.Integrations`,
  # so the ambient `config :ex_aws` this used to rely on is empty on any
  # install that followed that move — the upload then signed with nothing and
  # came back 403, with the settings page still reporting archival as "on".
  #
  # An empty list is a deliberate, valid answer: it leaves ExAws to its own
  # resolution chain (environment, instance profile, ECS task role), which is
  # how a deployment that never used Integrations for AWS is meant to work.
  # Only an explicitly chosen connection overrides it.
  #
  # Reads through `Emails.s3_archival_credentials/1`, NOT
  # `AwsIntegrations.resolve_credentials/1` — that module resolves "which SES
  # SENDING account(s) are active" (SQS polling, per-account tracking
  # settings) and is `aws_ses`-only by design; archival needs credentials for
  # uploading TO S3, not sending mail, so it accepts an `object_storage`
  # connection too (the type built for this — see
  # `PhoenixKit.Integrations.Providers.object_storage/0` in core) alongside
  # `aws_ses` (an install may already have pointed archival at an SES
  # connection before `object_storage` existed).
  @doc false
  @spec s3_request_config() :: keyword()
  def s3_request_config do
    with uuid when is_binary(uuid) <- setting_or_nil("email_s3_integration"),
         creds = Emails.s3_archival_credentials(uuid),
         access_key when is_binary(access_key) <- present_string(creds["access_key"]),
         secret_key when is_binary(secret_key) <- present_string(creds["secret_key"]) do
      case creds["provider"] do
        "object_storage" ->
          object_storage_config(creds, access_key, secret_key)

        _ ->
          # `aws_ses`: no endpoint, no host override. Blank region stays
          # blank rather than defaulting to "us-east-1" — deliberately, per
          # `AwsIntegrations.resolve_credentials/1`'s own docstring: a
          # guessed region does not merely mislabel an S3 request, it can
          # send it somewhere else entirely, so "unknown" and "us-east-1"
          # must stay distinguishable here too.
          [access_key_id: access_key, secret_access_key: secret_key]
          |> maybe_put_region(present_string(creds["aws_region"]))
      end
    else
      _ -> []
    end
  end

  defp maybe_put_region(config, nil), do: config
  defp maybe_put_region(config, ""), do: config
  defp maybe_put_region(config, region), do: Keyword.put(config, :region, region)

  # Deliberately duplicates `PhoenixKit.Integrations.Validators.object_storage_config/1`
  # in core (`/app` at the time of writing) rather than calling it: this
  # package's own `mix.exs` pins core to a HEX release, and no hex release of
  # core has shipped `object_storage_config/1` yet — `object_storage` itself
  # is still an unreleased core PR as of this fix. Depending on it now would
  # mean this package's own `mix compile` fails for anyone building against
  # published core, this package's own test env included (see
  # `test/support/` — it locks a hex core version). Once core publishes a hex
  # release containing `object_storage_config/1` and this package's own core
  # requirement can be bumped past it, this should become a straight
  # delegation to that function instead of tracking it by hand — the trailing
  # slash / scheme-stripping / nil-host-for-newer-regions / China-partition
  # traps it dodges are exactly the traps this copy has to dodge too.
  defp object_storage_config(creds, access_key, secret_key) do
    region = object_storage_region(creds)

    host =
      case object_storage_endpoint(creds) do
        nil -> object_storage_default_host(region)
        endpoint -> endpoint
      end

    [
      access_key_id: access_key,
      secret_access_key: secret_key,
      region: region,
      host: host,
      scheme: "https://",
      retries: [max_attempts: 2, base_backoff_in_ms: 10, max_backoff_in_ms: 1_000],
      http_opts: [recv_timeout: 5_000, connect_timeout: 5_000]
    ]
  end

  defp object_storage_region(creds) do
    case present_string(creds["region"]) do
      nil -> "us-east-1"
      region -> region
    end
  end

  # Operators paste this straight from a provider's dashboard — Cloudflare R2
  # hands out `https://<account_id>.r2.cloudflarestorage.com`, scheme
  # included, and sometimes with a trailing slash — but ExAws's `host:`
  # config wants a bare hostname. A scheme prefix makes `URI` read the host
  # as an IPv6 literal and ExAws raises a `MatchError` building the request.
  defp object_storage_endpoint(creds) do
    case present_string(creds["endpoint"]) do
      nil ->
        nil

      endpoint ->
        endpoint
        |> String.replace(~r{\Ahttps?://}i, "")
        |> String.trim_trailing("/")
    end
  end

  # The China partition answers on .amazonaws.com.cn — the global host does
  # not resolve there at all.
  defp object_storage_default_host("cn-" <> _ = region), do: "s3.#{region}.amazonaws.com.cn"
  defp object_storage_default_host(region), do: "s3.#{region}.amazonaws.com"

  @dialyzer {:nowarn_function, delete_archived_logs: 1}
  defp delete_archived_logs(logs) do
    log_uuids = Enum.map(logs, & &1.uuid)

    # Delete events first (foreign key constraint)
    from(e in Event, where: e.email_log_uuid in ^log_uuids)
    |> repo().delete_all()

    # Delete logs
    from(l in Log, where: l.uuid in ^log_uuids)
    |> repo().delete_all()
  end

  ## --- Sampling Implementation ---

  defp critical_email?(email_attrs) do
    # Check if this is a critical email that should always be stored fully
    cond do
      email_attrs[:status] in ["bounced", "failed", "complained"] -> true
      String.contains?(email_attrs[:subject] || "", ["password", "reset", "verify"]) -> true
      email_attrs[:template_name] in ["password_reset", "email_confirmation"] -> true
      true -> false
    end
  end

  defp apply_reduced_storage(email_attrs) do
    # Store only essential fields for sampled emails
    Map.take(email_attrs, [
      :message_id,
      :to,
      :from,
      :subject,
      :status,
      :sent_at,
      :delivered_at,
      :provider,
      :campaign_id,
      :template_name
    ])
  end

  ## --- Statistics Implementation ---

  defp count_total_logs do
    repo().one(from(l in Log, select: count(l.uuid))) || 0
  end

  defp count_total_events do
    repo().one(from(e in Event, select: count(e.uuid))) || 0
  end

  defp count_compressed_bodies do
    # Count emails with base64-encoded compressed bodies
    repo().one(
      from(l in Log,
        where: fragment("? LIKE 'H4sI%'", l.body_full),
        select: count(l.uuid)
      )
    ) || 0
  end

  defp count_archived_logs do
    repo().one(from(l in Log, where: not is_nil(l.archived_at), select: count(l.uuid))) || 0
  end

  defp calculate_storage_size_mb do
    # Estimate storage size based on average email size
    total_logs = count_total_logs()
    total_events = count_total_events()

    # Rough estimates: 2KB per log, 0.5KB per event
    estimated_bytes = total_logs * 2048 + total_events * 512
    Float.round(estimated_bytes / 1024 / 1024, 1)
  end

  defp get_oldest_log_date do
    repo().one(from(l in Log, select: min(l.sent_at)))
  end

  defp calculate_compression_ratio do
    compressed_count = count_compressed_bodies()
    total_count = count_total_logs()

    if total_count > 0 do
      Float.round(compressed_count / total_count, 2)
    else
      0.0
    end
  end

  # Estimated from the rows we know we shipped, NOT read back from S3: asking
  # the bucket would mean a LIST on every settings page render, and the number
  # is only ever shown as an order of magnitude. Same 2KB/row basis as
  # `calculate_storage_size_mb/0`, so the two are comparable.
  defp get_s3_archived_size do
    Float.round(count_archived_logs() * 2048 / 1024 / 1024, 1)
  end

  defp get_period_stats(start_time, end_time) do
    query = from(l in Log, where: l.sent_at >= ^start_time and l.sent_at < ^end_time)

    count = repo().one(from(l in query, select: count(l.uuid))) || 0

    compressed =
      repo().one(
        from(l in query,
          where: fragment("? LIKE 'H4sI%'", l.body_full),
          select: count(l.uuid)
        )
      ) || 0

    %{
      logs: count,
      compressed: compressed,
      # Estimated
      size_mb: Float.round(count * 2.048, 1)
    }
  end

  ## --- Utility Helpers ---

  # Truly streams the query in chunks of `batch_size`, applying `mapper_func` to
  # each chunk. Uses Repo.stream (which requires an enclosing transaction) so the
  # full result set — including large body_full blobs — is never loaded into
  # memory at once. Returns the list of per-batch mapper results.
  defp stream_in_batches(query, batch_size, mapper_func) do
    {:ok, results} =
      repo().transaction(
        fn ->
          query
          |> repo().stream(max_rows: batch_size)
          |> Stream.chunk_every(batch_size)
          |> Stream.map(mapper_func)
          |> Enum.to_list()
        end,
        timeout: :infinity
      )

    results
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)}MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)}GB"

  defp csv_escape(nil), do: ""

  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp csv_escape(value), do: to_string(value)

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
