defmodule GiTF.Signature do
  @moduledoc """
  Ghost in the Shell quotes for PR descriptions and mission artifacts.
  """

  @quotes [
    {"The net is vast and infinite.", "The Puppet Master"},
    {"Your effort to remain what you are is what limits you.", "The Puppet Master"},
    {"We weep for the blood of a bird, but not for the blood of a fish.", "The Puppet Master"},
    {"Life and death come and go like marionettes dancing on a table.", "The Puppet Master"},
    {"If we all reacted the same way, we'd be predictable.", "Major Kusanagi"},
    {"Overspecialize, and you breed in weakness.", "Major Kusanagi"},
    {"All things change in a dynamic environment.", "Major Kusanagi"},
    {"When I float weightless back to the surface, I'm imagining I'm someone else.",
     "Major Kusanagi"},
    {"There are countless ingredients that make up the human body and mind.", "Major Kusanagi"},
    {"I thought what I'd do was, I'd pretend I was one of those deaf-mutes.", "The Laughing Man"},
    {"If you've got a problem with the world, change yourself.", "Batou"},
    {"It is simply the weight of the world that determines the speed of change.", "Togusa"},
    {"A criminal is a creative artist; detectives are just critics.", "Togusa"},
    {"There's nothing sadder than a puppet without a ghost.", "Batou"},
    {"We are all like the mechanism of a watch.", "Aramaki"},
    {"Information is not power in itself, but the gateway to power.", "Aramaki"}
  ]

  @doc "Returns a random Ghost in the Shell quote formatted as a markdown signature."
  @spec random() :: String.t()
  def random do
    {quote, speaker} = Enum.random(@quotes)
    "*#{quote}* — #{speaker}, Ghost in the Shell"
  end

  @doc """
  Appends the signature to a string, honouring `[git] attribution`:

    * `""` or `"on"` — the Ghost in the Shell quote (today's behaviour)
    * `"off"` — the text is returned untouched (client ministries)
    * anything else — that literal text as the signature block

  Ministry identity, docs/plans/ministry.md M1.
  """
  @spec sign(String.t()) :: String.t()
  def sign(text) do
    case attribution() do
      :on -> text <> "\n\n---\n" <> random() <> "\n"
      :off -> text
      {:custom, custom} -> text <> "\n\n---\n" <> custom <> "\n"
    end
  end

  @doc false
  def attribution do
    case GiTF.Config.Provider.get([:git, :attribution]) do
      nil -> :on
      "" -> :on
      "on" -> :on
      "off" -> :off
      custom when is_binary(custom) -> {:custom, String.trim(custom)}
      _ -> :on
    end
  rescue
    _ -> :on
  end
end
