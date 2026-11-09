defmodule Tussle.Cache.MemoryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Tussle.Cache.Memory

  defmodule StubStorage do
    @behaviour Tussle.Storage

    def create(file, _config), do: file
    def append(file, _config, _body), do: {:ok, file}
    def complete_upload(file, _config), do: {:ok, file}

    def delete(file, %{test_pid: test_pid} = config) do
      send(test_pid, {:storage_delete, file.uid})
      Map.get(config, :delete_result, :ok)
    end
  end

  # test_helper.exs already runs one Memory cache for Tussle.TestController, so
  # starting more here exercises several caches sharing a VM.
  test "several caches run side by side with independent tables" do
    first = Module.concat(__MODULE__, FirstCache)
    second = Module.concat(__MODULE__, SecondCache)

    start_supervised!({Memory, %{cache_name: first}}, id: first)
    start_supervised!({Memory, %{cache_name: second}}, id: second)

    Memory.put(first, "shared-key", %{offset: 1})
    Memory.put(second, "shared-key", %{offset: 2})

    assert Memory.get(first, "shared-key") == %{offset: 1}
    assert Memory.get(second, "shared-key") == %{offset: 2}

    Memory.delete(first, "shared-key")

    assert is_nil(Memory.get(first, "shared-key"))
    assert Memory.get(second, "shared-key") == %{offset: 2}
  end

  describe "expiration" do
    defp start_cache(context, extra_config \\ %{}) do
      name = Module.concat(__MODULE__, context.test)

      config =
        %{
          cache_name: name,
          storage: StubStorage,
          test_pid: self(),
          # Long enough that the real timer never fires during a test; sweeps
          # are triggered by hand with send/2.
          expiration_period: 3_600
        }
        |> Map.merge(extra_config)

      pid = start_supervised!({Memory, config}, id: name)
      {name, pid}
    end

    defp file(uid, age_seconds) do
      %Tussle.File{uid: uid, created_at: DateTime.to_unix(DateTime.utc_now()) - age_seconds}
    end

    defp sweep(name, pid) do
      send(pid, :expire_timer)
      # A synchronous call ensures the sweep has been processed before asserting.
      _ = Memory.get(name, :sync)
    end

    test "a sweep removes expired entries and deletes them from storage", context do
      {name, pid} = start_cache(context)

      Memory.put(name, "old", file("old", 3_601))
      Memory.put(name, "fresh", file("fresh", 10))

      sweep(name, pid)

      assert_received {:storage_delete, "old"}
      refute_received {:storage_delete, "fresh"}

      assert is_nil(Memory.get(name, "old"))
      assert %Tussle.File{uid: "fresh"} = Memory.get(name, "fresh")
    end

    test "an entry expires once it reaches Upload-Expires, not after", context do
      {name, pid} = start_cache(context, %{expiration_period: 100})

      Memory.put(name, "at-limit", file("at-limit", 100))
      Memory.put(name, "just-under", file("just-under", 99))

      sweep(name, pid)

      assert is_nil(Memory.get(name, "at-limit"))
      assert %Tussle.File{uid: "just-under"} = Memory.get(name, "just-under")
    end

    test "an entry is dropped from the cache even when storage deletion fails", context do
      {name, pid} = start_cache(context, %{delete_result: {:error, :enoent}})

      Memory.put(name, "old", file("old", 3_601))

      sweep(name, pid)

      assert_received {:storage_delete, "old"}
      assert is_nil(Memory.get(name, "old"))
    end

    test "the sweep timer starts on init and keeps running", context do
      {name, _pid} = start_cache(context, %{expiration_period: 1})

      Memory.put(name, "old", file("old", 5))

      # Only the timer started in init/1 can remove this entry; nothing
      # sends :expire_timer by hand here.
      assert_receive {:storage_delete, "old"}, 2_000
      assert is_nil(Memory.get(name, "old"))

      # The timer is periodic, so an entry added afterwards also goes.
      Memory.put(name, "later", file("later", 5))
      assert_receive {:storage_delete, "later"}, 2_000
      assert is_nil(Memory.get(name, "later"))
    end

    test "sweeps queued behind a slow sweep are dropped with a warning", context do
      {name, pid} = start_cache(context)

      Memory.put(name, "old", file("old", 3_601))

      # Suspend the server so two timer messages pile up in its mailbox, the
      # way they would if a sweep outlasted expiration_period.
      :ok = :sys.suspend(pid)
      send(pid, :expire_timer)
      send(pid, :expire_timer)
      send(pid, :expire_timer)

      log =
        capture_log(fn ->
          :ok = :sys.resume(pid)
          _ = Memory.get(name, :sync)
        end)

      assert log =~ "expiration sweep is falling behind"
      assert log =~ "2 sweep(s) were already queued"

      # Only the first sweep ran; the queued ones were discarded, not replayed.
      assert_received {:storage_delete, "old"}
      refute_received {:storage_delete, "old"}
      assert is_nil(Memory.get(name, "old"))
    end

    test "without expiration_period nothing is ever expired", context do
      name = Module.concat(__MODULE__, context.test)

      pid =
        start_supervised!(
          {Memory, %{cache_name: name, storage: StubStorage, test_pid: self()}},
          id: name
        )

      Memory.put(name, "ancient", file("ancient", 1_000_000))

      sweep(name, pid)

      refute_received {:storage_delete, _}
      assert %Tussle.File{uid: "ancient"} = Memory.get(name, "ancient")
      assert Process.alive?(pid)
    end
  end
end
