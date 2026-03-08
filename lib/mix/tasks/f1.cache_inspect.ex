defmodule Mix.Tasks.F1.CacheInspect do
  @moduledoc """
  Inspect replay cache rows stored in DuckDB.

  Examples:

      mix f1.cache_inspect
      mix f1.cache_inspect --session-key 11230
      mix f1.cache_inspect --endpoint location --limit 50
  """

  use Mix.Task

  @shortdoc "Inspect DuckDB replay cache"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [session_key: :integer, endpoint: :string, limit: :integer]
      )

    duckdb =
      System.find_executable("duckdb") ||
        Mix.raise("duckdb CLI is not installed or not on PATH")

    db_path =
      Application.get_env(:f1_tracker, :openf1_replay_cache_db) ||
        Path.join(System.tmp_dir!(), "f1_tracker_replay_cache/replay_cache.duckdb")

    unless File.exists?(db_path) do
      Mix.raise("Replay cache DB does not exist at #{db_path}")
    end

    limit = max(opts[:limit] || 20, 1)
    where_clause = build_where(opts)

    summary_sql =
      """
      SELECT endpoint, session_key, COUNT(*) AS chunks
      FROM replay_chunk_cache
      #{where_clause}
      GROUP BY endpoint, session_key
      ORDER BY chunks DESC;
      """

    rows_sql =
      """
      SELECT endpoint, session_key, from_iso, to_iso, inserted_at, LENGTH(payload_json) AS payload_bytes
      FROM replay_chunk_cache
      #{where_clause}
      ORDER BY inserted_at DESC
      LIMIT #{limit};
      """

    Mix.shell().info("Replay cache DB: #{db_path}")
    Mix.shell().info("\nSummary:\n")
    run_query(duckdb, db_path, summary_sql)

    Mix.shell().info("\nRecent rows:\n")
    run_query(duckdb, db_path, rows_sql)
  end

  defp build_where(opts) do
    clauses =
      []
      |> maybe_add_clause(opts[:session_key], fn sk -> "session_key = #{sk}" end)
      |> maybe_add_clause(opts[:endpoint], fn endpoint ->
        escaped = String.replace(endpoint, "'", "''")
        "endpoint = '#{escaped}'"
      end)

    case clauses do
      [] -> ""
      _ -> "WHERE " <> Enum.join(clauses, " AND ")
    end
  end

  defp maybe_add_clause(clauses, nil, _builder), do: clauses
  defp maybe_add_clause(clauses, value, builder), do: clauses ++ [builder.(value)]

  defp run_query(duckdb, db_path, sql) do
    case System.cmd(duckdb, [db_path, sql], stderr_to_stdout: true) do
      {output, 0} -> Mix.shell().info(output)
      {output, status} -> Mix.raise("duckdb query failed (#{status}):\n#{output}")
    end
  end
end
