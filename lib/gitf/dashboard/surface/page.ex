defmodule GiTF.Dashboard.Surface.Page do
  @moduledoc """
  The shape of a page about one thing.

  Every object in the system — a mission, an op, a sector, a ministry — is worth
  looking at the same way: a trail showing where it sits, a head naming it and
  saying what state it is in, a row of things you can do to it, and a body at
  whatever depth you asked for. The Console was built on that shape; the Catwalk
  had twenty-nine pages each inventing their own header.

  ## Depth is part of the address

  Overview, Evidence, Raw are links, not clicks. A page at a particular depth is
  a page you can send to someone, and Raw means the simplified view is never a
  dead end — whatever the page decided not to show you is one click away, as the
  record itself.

  Not every object has three depths worth having; pass the ones it does.
  """

  use Phoenix.Component

  import GiTF.Dashboard.Surface.Components

  @doc """
  The frame: trail, head, depth tabs, body.

  `crumbs` is `{label, path}` — the last one is where you are. `tabs` is
  `{label, path, current?}`, already resolved, and is omitted entirely when a
  page has only one depth.
  """
  attr(:kind, :string, required: true, doc: "what sort of thing this is")
  attr(:name, :string, required: true)
  attr(:sub, :string, default: nil, doc: "one line under the name — the goal, the path")
  attr(:crumbs, :list, default: [])
  attr(:tabs, :list, default: [])
  attr(:link, :atom, default: :navigate, doc: ":navigate across LiveViews, :patch within one")
  slot(:badges)
  slot(:metrics)
  slot(:actions)
  slot(:inner_block, required: true)

  def object(assigns) do
    ~H"""
    <.scopebar :if={@crumbs != []} crumbs={@crumbs} link={@link} />

    <.object_head kind={@kind} name={@name} sub={@sub}>
      <:badges>{render_slot(@badges)}</:badges>
      <:metrics>{render_slot(@metrics)}</:metrics>
      <:actions>{render_slot(@actions)}</:actions>
    </.object_head>

    <.tabs :if={@tabs != []} tabs={@tabs} link={@link} />

    <div class="objbody">{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  The depth tabs for a page whose depth lives in a query parameter.

  `?t=raw` rather than a path segment, because depth is a lens on the object and
  not a different object: it should survive when you move to the next one.
  """
  @spec depths(String.t(), String.t() | nil, [{String.t(), String.t()}]) ::
          [{String.t(), String.t(), boolean()}]
  def depths(base_path, current, offered) do
    current = if current in Enum.map(offered, &elem(&1, 0)), do: current, else: "overview"

    Enum.map(offered, fn {id, label} ->
      path = if id == "overview", do: base_path, else: "#{base_path}?t=#{id}"
      {label, path, id == current}
    end)
  end

  @doc "The three depths most objects offer."
  def standard_depths,
    do: [{"overview", "Overview"}, {"evidence", "Evidence"}, {"raw", "Raw"}]
end
