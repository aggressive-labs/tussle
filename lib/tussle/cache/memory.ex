defmodule Tussle.Cache.Memory do
  use GenServer

  # Public API ----------------------------------------------------------------

  def start_link(%{cache_name: cache_name} = config) do
    GenServer.start_link(
      __MODULE__,
      [
        {:log_limit, 1_000_000},
        {:config, config}
      ],
      name: cache_name
    )
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

  def handle_info({:expire_timer, now}, state) do
    %{ets_table_name: ets_table_name, config: config} = state

    expiration_period =
      config
      |> Map.get(:expiration_period)

    expire_entries(ets_table_name, now, config)

    maybe_add_expiration_timer(expiration_period)
    {:noreply, state}
  end

  def init(args) do
    [{:log_limit, log_limit}, {:config, config}] = args

    # One unnamed table per cache process, so several controllers can each
    # run their own memory cache in the same VM.
    ets_table_name = :ets.new(:tussle_cache_table, [:set, :private])

    {:ok, %{log_limit: log_limit, ets_table_name: ets_table_name, config: config}}
  end

  defp maybe_add_expiration_timer(nil), do: nil

  defp maybe_add_expiration_timer(ttl) do
    # ttl is in seconds, convert to milliseconds for timer
    period_ms = ttl * 1_000
    # Store expiration time as unix timestamp in seconds
    expires_at = DateTime.to_unix(DateTime.utc_now()) + ttl
    Process.send_after(self(), {:expire_timer, expires_at}, period_ms)
  end

  defp expire_entries(ets_table_name, now, config) do
    expiration_period = Map.get(config, :expiration_period, 86_400)

    ets_table_name
    |> :ets.tab2list()
    |> Enum.filter(fn {_k, entry} ->
      # now and created_at are both unix timestamps in seconds
      age = now - entry.created_at
      age > expiration_period
    end)
    |> Enum.each(fn {key, entry} ->
      case Tussle.storage_delete(entry, config) do
        :ok ->
          :ets.delete(ets_table_name, key)

        _err ->
          :ets.delete(ets_table_name, key)
      end
    end)
  end
end
