defmodule GiTF.WorktreeLock do
  @moduledoc """
  Serializes toolchain-touching command runs per sector.

  Run 7 (msn-4fda11): the validation phase's exec validation and the
  op-level audit both launched the sector's validation command at
  18:27:10 — two concurrent `npm ci` runs in the same tree tore
  node_modules apart (TAR_ENTRY_ERROR), every subsequent tool call
  exited 127, and the mission burned its entire fix budget on an
  infrastructure failure. The sector is also the scope of the runtime
  probe's port/display locks ("probe lock busy"), so the lock key is the
  sector, not the individual worktree.

  Uses `:global.trans/4` with infinite retries: callers queue rather
  than fail, and a lock dies with its holding process. The wrapped
  commands all carry their own timeouts, so waits are bounded. Do not
  nest `with_lock` calls with the same key in one process — the lock is
  not reentrant.
  """

  @spec with_lock(term(), (-> result)) :: result when result: var
  def with_lock(key, fun) when is_function(fun, 0) do
    :global.trans({{__MODULE__, key}, self()}, fun, [node()], :infinity)
  end
end
