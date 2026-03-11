defmodule GiTF.ID do
  @moduledoc "Generates short, human-friendly identifiers for GiTF entities."

  @prefixes ~w(ghost job qst cmb cel wag cst jdp cnl qpt crc rfi vrf mrp crp erp apr prv ckp msc evt agi run)a

  @doc """
  Generates a prefixed identifier like `"ghost-a1b2c3"`.

  ## Examples

      iex> id = GiTF.ID.generate(:ghost)
      iex> String.starts_with?(id, "ghost-")
      true
  """
  @spec generate(atom()) :: String.t()
  def generate(prefix) when prefix in @prefixes do
    suffix =
      :crypto.strong_rand_bytes(3)
      |> Base.encode16(case: :lower)

    "#{prefix}-#{suffix}"
  end
end
