defmodule Hive.ID do
  @moduledoc "Generates short, human-friendly identifiers for Hive entities."

  @prefixes ~w(bee job qst cmb cel wag cst jdp cnl qpt crc rfi vrf mrp crp erp)a

  @doc """
  Generates a prefixed identifier like `"bee-a1b2c3"`.

  ## Examples

      iex> id = Hive.ID.generate(:bee)
      iex> String.starts_with?(id, "bee-")
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
