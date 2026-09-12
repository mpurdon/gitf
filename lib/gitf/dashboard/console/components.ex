defmodule GiTF.Dashboard.Console.Components do
  @moduledoc """
  The Console's primitives.

  The old console wrote a ministry's identity block out four times, with three
  different sets of fields, and its action cluster twice with different labels
  for the same act — `Sleep` here, `Stop factory` there. Everything shared
  lives here instead, so a change to how an object is presented is one edit and
  the same everywhere.

  The set is deliberately operational rather than generic: an identity, a
  health dot, a metric, a navigable row, a relation, a decision factor. These
  are the shapes the domain actually has.
  """

  use Phoenix.Component

  alias GiTF.Dashboard.Console.Scope

  # -- status ----------------------------------------------------------------

  @doc "A semantic dot. Colour means something here, so `nil` is the common case."
  attr(:tone, :atom, default: nil)

  def dot(assigns) do
    ~H"""
    <span class={["dot", @tone && to_string(@tone)]}></span>
    """
  end

  @doc "A status pill. `tone` is semantic; `acc` is the accent, which is not a status."
  attr(:tone, :atom, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def pill(assigns) do
    ~H"""
    <span class={["pill", @tone && to_string(@tone)]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc "Label above value, monospaced and tabular so columns of numbers line up."
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :atom, default: nil)

  def metric(assigns) do
    ~H"""
    <div class="metric">
      <span class="lbl">{@label}</span>
      <span class="v" style={@tone && "color:var(--#{@tone})"}>{@value}</span>
    </div>
    """
  end

  # -- object chrome ---------------------------------------------------------

  @doc """
  The head of an object page: what kind of thing it is, what it is called, the
  identifiers underneath, its state, its numbers, and what you can do to it.

  Every object gets the same shape so that moving between a ministry, a
  ruleset and a registration feels like moving through one system.
  """
  attr(:kind, :string, required: true)
  attr(:name, :string, required: true)
  attr(:sub, :string, default: nil)
  slot(:badges)
  slot(:metrics)
  slot(:actions)

  def object_head(assigns) do
    ~H"""
    <div class="objhead">
      <div class="lbl">{@kind}</div>
      <div class="idl">
        <h2>{@name}</h2>
        {render_slot(@badges)}
      </div>
      <div :if={@sub} class="sub">{@sub}</div>
      <div :if={@metrics != []} class="mrow">{render_slot(@metrics)}</div>
      <div :if={@actions != []} class="acts">{render_slot(@actions)}</div>
      <div :if={@metrics == [] and @actions == []} style="height:14px"></div>
    </div>
    """
  end

  @doc "The trail of ancestors, each a link back to itself."
  attr(:crumbs, :list, required: true)
  slot(:inner_block)

  def scopebar(assigns) do
    ~H"""
    <div class="scopebar">
      <%= for {{label, path}, i} <- Enum.with_index(@crumbs) do %>
        <span :if={i > 0} class="sep">›</span>
        <.link
          patch={path}
          class="crumb"
          aria-current={if i == length(@crumbs) - 1, do: "page"}
        >{label}</.link>
      <% end %>
      <span style="margin-left:auto;display:flex;gap:12px;align-items:center">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc """
  Overview · Evidence · Raw, as links rather than clicks.

  Depth is part of the address: a link to the evidence for a decision is
  something you can send to someone.
  """
  attr(:scope, :map, required: true)

  def tabs(assigns) do
    assigns = assign(assigns, :tabs, Scope.tabs(assigns.scope))

    ~H"""
    <div class="tabsrow">
      <.link
        :for={{id, label} <- @tabs}
        patch={Scope.to_path(Scope.with_tab(@scope, id))}
        aria-current={if @scope.tab == id, do: "page"}
      >{label}</.link>
    </div>
    """
  end

  @doc "A titled block with an optional right-hand aside."
  attr(:title, :string, required: true)
  slot(:hint)
  slot(:inner_block, required: true)

  def section(assigns) do
    ~H"""
    <div class="sect">
      <h3>{@title}<span :if={@hint != []} class="hint">{render_slot(@hint)}</span></h3>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "A bordered group of rows. Empty is a sentence, never a blank box."
  attr(:empty, :string, default: nil)
  slot(:inner_block, required: true)

  def rows(assigns) do
    ~H"""
    <div class="rows">
      {render_slot(@inner_block)}
      <div :if={@empty} class="empty">{@empty}</div>
    </div>
    """
  end

  @doc """
  One row. `to` makes it a link — information doubling as navigation, which is
  the point: if you can see something interesting you should be able to select it.
  """
  attr(:cols, :string, required: true)
  attr(:to, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def row(assigns) do
    ~H"""
    <.link :if={@to} patch={@to} class="row" style={"grid-template-columns:#{@cols}"} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <div :if={!@to} class="row" style={"grid-template-columns:#{@cols}"} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Name over identifier — the two things that tell you which object this is."
  attr(:name, :string, required: true)
  attr(:id, :string, default: nil)

  def identity(assigns) do
    ~H"""
    <span style="min-width:0">
      <span class="nm">{@name}</span>
      <br :if={@id} /><span :if={@id} class="dim">{@id}</span>
    </span>
    """
  end

  @doc """
  A navigable semantic connection: *governed by*, *receives*, *led to*.

  Relations are how you move sideways through the system rather than back up
  and down the tree.
  """
  slot :rel, doc: "one relation" do
    attr(:verb, :string, required: true)
    attr(:to, :string)
  end

  def relations(assigns) do
    ~H"""
    <div class="rel">
      <%= for r <- @rel do %>
        <.link :if={r[:to]} patch={r.to}>
          <span class="verb">{r.verb}</span>
          <span>{render_slot(r)}</span>
          <span style="margin-left:auto;color:var(--ink-3)">›</span>
        </.link>
        <div :if={!r[:to]}>
          <span class="verb">{r.verb}</span>
          <span>{render_slot(r)}</span>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  One contributing fact behind a decision: the claim on the left, the evidence
  for it on the right. Stacked, these are a why-chain.
  """
  attr(:detail, :string, default: nil)
  slot(:inner_block, required: true)

  def factor(assigns) do
    ~H"""
    <div class="factor">
      <div>{render_slot(@inner_block)}</div>
      <div :if={@detail} class="d">{@detail}</div>
    </div>
    """
  end

  @doc "A statement that needed saying: a draft in progress, a failure, a warning."
  attr(:tone, :atom, default: :warn)
  slot(:inner_block, required: true)

  def banner(assigns) do
    ~H"""
    <div class={["banner", to_string(@tone)]}>
      <.dot tone={@tone} />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc "The expert view of whatever is above it. The simplified UI is never a dead end."
  attr(:term, :any, required: true)
  attr(:note, :string, default: nil)

  def raw(assigns) do
    ~H"""
    <p :if={@note} class="note" style="margin:0 0 12px">{@note}</p>
    <pre class="raw">{inspect(@term, pretty: true, limit: :infinity, printable_limit: 8_192)}</pre>
    """
  end

  # -- the tree --------------------------------------------------------------

  @doc "The fleet, as one rail. Nodes come from `Console.Tree`."
  attr(:nodes, :list, required: true)

  def tree(assigns) do
    ~H"""
    <nav class="pane tree" aria-label="Fleet">
      <div class="tsearch">
        <span aria-hidden="true">⌕</span>
        <span>Search the fleet</span>
        <span style="margin-left:auto;font-family:var(--mono);font-size:10px">⌘K</span>
      </div>
      <%= for node <- @nodes do %>
        <div :if={node.kind == :group} class="tgroup" style={indent(node)}>{node.label}</div>
        <div :if={node.kind == :hint} class="thint" style={indent(node)}>{node.label}</div>
        <.link
          :if={node.kind not in [:group, :hint] and node.path}
          patch={node.path}
          class="tnode"
          style={indent(node)}
          aria-current={if node.current?, do: "page"}
        >
          <span class="tw">{node.twist}</span>
          <.dot :if={node.tone} tone={node.tone} />
          <span class="tn">{node.label}</span>
          <span :if={node.tail} class={["tt", node.tail_tone && to_string(node.tail_tone)]}>
            {node.tail}
          </span>
        </.link>
        <div
          :if={node.kind not in [:group, :hint] and is_nil(node.path)}
          class="tnode"
          style={indent(node)}
        >
          <span class="tw">{node.twist}</span>
          <.dot :if={node.tone} tone={node.tone} />
          <span class="tn">{node.label}</span>
          <span :if={node.tail} class={["tt", node.tail_tone && to_string(node.tail_tone)]}>
            {node.tail}
          </span>
        </div>
      <% end %>
    </nav>
    """
  end

  defp indent(%{depth: depth}), do: "padding-left:#{8 + depth * 15}px"
end
