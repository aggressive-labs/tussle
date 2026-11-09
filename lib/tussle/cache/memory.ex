defmodule Tussle.Cache.Memory do
  use GenServer
  require Logger

  # Public API ----------------------------------------------------------------

  def start_link(%{cache_name: cache_name} = config) do
    GenServer.start_link(__MODULE__, config, name: cache_name)
  end

  def get(name, key) do
    case GenServer.call(name, {:get, key}) do
      [] -> nil
      [{_key, file}] -> file
    end
  end

  def put(name, key, file) do
    GenServer.call(name, {:set, key, file})
  end

  def delete(name, key) do
    GenServer.cast(name, {:delete, key})
  end

  # Server --------------------------------------------------------------------

  def init(config) do
    # One unnamed table per cache process, so several controllers can each
    # run their own memory cache in the same VM.
    ets_table_name = :ets.new(:tussle_cache_table, [:set, :private])

    start_expiration_timer(Map.get(config, :expiration_period))

    {:ok, %{ets_table_name: ets_table_name, config: config}}
  end

  def handle_call({:get, key}, _from, state) do
    %{ets_table_name: ets_table_name} = state
    {:reply, :ets.lookup(ets_table_name, key), state}
  end

  def handle_call({:set, key, file}, _from, state) do
    %{ets_table_name: ets_table_name} = state
    true = :ets.insert(ets_table_name, {key, file})
    {:reply, file, state}
  end

  def handle_cast({:delete, key}, state) do
    %{ets_table_name: ets_table_name} = state
    :ets.delete(ets_table_name, key)
    {:noreply, state}
  end

  def handle_info(:expire_timer, state) do
    %{ets_table_name: ets_table_name, config: config} = state

    case Map.get(config, :expiration_period) do
      nil ->
        :ok

      expiration_period ->
        now = DateTime.to_unix(DateTime.utc_now())
        expire_entries(ets_table_name, now - expiration_period, config)
        drop_queued_sweeps(expiration_period)
    end

    {:noreply, state}
  end

  defp start_expiration_timer(nil), do: nil

  defp start_expiration_timer(ttl) do
    # A periodic timer owned by the timer server rather than a timer the sweep
    # re-arms itself: anything that cuts a sweep short cannot stop the next one.
    # It is cancelled automatically when this process exits.
    {:ok, _tref} = :timer.send_interval(ttl * 1_000, :expire_timer)
  end

  # The interval timer keeps firing while a slow sweep runs. Running the queued
  # sweeps back to back would find nothing new, so they are discarded, with a
  # warning because it means sweeps take longer than expiration_period.
  defp drop_queued_sweeps(expiration_period) do
    case drain_expire_timers(0) do
      0 ->
        :ok

      queued ->
        Logger.warning(
          "Tussle.Cache.Memory expiration sweep is falling behind: " <>
            "#{queued} sweep(s) were already queued when the previous one finished. " <>
            "Sweeps are taking longer than expiration_period (#{expiration_period}s)."
        )
    end
  end

  defp drain_expire_timers(count) do
    receive do
      :expire_timer -> drain_expire_timers(count + 1)
    after
      0 -> count
    end
  end

  # Removes every entry created at or before `cutoff` (a unix timestamp in
  # seconds) and deletes its partial upload from storage.
  defp expire_entries(ets_table_name, cutoff, config) do
    match_spec = [
      {{:"$1", %{created_at: :"$2"}}, [{:"=<", :"$2", cutoff}], [:"$_"]}
    ]

    ets_table_name
    |> :ets.select(match_spec)
    |> Enum.each(fn {key, file} ->
      case Tussle.storage_delete(file, config) do
        :ok ->
          :ok

        err ->
          Logger.warning(
            "Tussle.Cache.Memory could not delete expired upload #{inspect(key)} from storage: #{inspect(err)}"
          )
      end

      :ets.delete(ets_table_name, key)
    end)
  end
end
