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

  @doc "Appends the signature to a string with a horizontal rule."
  @spec sign(String.t()) :: String.t()
  def sign(text) do
    text <> "\n\n---\n" <> random() <> "\n"
  end
end
