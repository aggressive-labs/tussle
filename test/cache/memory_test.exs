defmodule Tussle.Cache.MemoryTest do
  use ExUnit.Case, async: true

  alias Tussle.Cache.Memory

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
end
