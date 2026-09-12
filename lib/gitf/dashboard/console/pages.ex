defmodule GiTF.Dashboard.Console.Pages do
  @moduledoc """
  One page per object, each in the same three depths: an **Overview** a person
  reads, the **Evidence** behind it, and the **Raw** record underneath.

  The rule the old console broke: the simplified view is never a dead end. Its
  inspector rendered the Overview and the Why tabs from identical markup, so
  the tab that promised an explanation gave you the summary again.
  """

  use Phoenix.Component

  import GiTF.Dashboard.Console.Components

  alias GiTF.Cabinet.JDM
  alias GiTF.Dashboard.Console.{Format, Scope}

  # ==========================================================================
  # Cabinet
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:ministries, :list, required: true)
  attr(:activity, :list, required: true)
  attr(:inbox, :list, required: true)
  attr(:cabinet, :map, required: true)

  def cabinet(%{scope: %{tab: "raw"}} = assigns) do
    ~H"""
    <.raw term={@cabinet} note="The Cabinet as it knows itself." />
    """
  end

  def cabinet(%{scope: %{tab: "evidence"}} = assigns) do
    ~H"""
    <.section title="Recent acts">
      <:hint><.link patch={Scope.path(@scope, :activity)} class="chip">the whole log ›</.link></:hint>
      <.rows empty={@activity == [] && "Nothing yet — wakes, stops, mode changes and starts land here."}>
        <.row :for={a <- Enum.take(@activity, 12)} cols="66px 128px minmax(0,1fr) auto">
          <span class="dim">{Format.hhmm(a[:at])}</span>
          <span class="dim">{a[:actor]}</span>
          <span class="nm">{a[:action]} <span style="color:var(--accent)">{a[:target]}</span></span>
          <span class="dim">{a[:result]}</span>
        </.row>
      </.rows>
    </.section>
    """
  end

  def cabinet(assigns) do
    ~H"""
    <.section title="Ministries">
      <:hint>
        <.link patch={Scope.path(@scope, :registration, ministry: "new")} class="chip">
          + register a ministry
        </.link>
      </:hint>
      <.rows empty={@ministries == [] && "No ministries registered yet."}>
        <.row
          :for={m <- @ministries}
          cols="16px 1.3fr 96px minmax(0,1fr) 116px"
          to={Scope.path(@scope, :ministry, ministry: m.slug)}
        >
          <.dot tone={Format.state_tone(m)} />
          <.identity name={m[:name] || m.slug} id={m.slug} />
          <.pill tone={Format.state_tone(m)}>{Format.state_label(m)}</.pill>
          <span class="dim">{Format.sleeps_in(m)}</span>
          <span class="dim">{Format.spend_line(m)}</span>
        </.row>
      </.rows>
    </.section>

    <.section title="Waiting on you">
      <:hint><.link patch={Scope.path(@scope, :activity)} class="chip">the inbox ›</.link></:hint>
      <%!-- Queued only. Listing every activation under a heading that says
            "waiting on you" is the same lie as a count that disagrees with
            the rows under it — and it was doing both at once. --%>
      <.rows empty={Format.queued(@inbox) == [] && "Nothing is waiting on you."}>
        <.row :for={e <- Enum.take(Format.queued(@inbox), 5)} cols="86px minmax(0,1fr) 92px">
          <.pill>{e[:class]}</.pill>
          <.identity name={e[:summary]} id={"#{e[:ministry_slug]} · #{Format.decision_line(e)}"} />
          <span class="dim">{Format.hhmm(e[:inserted_at])}</span>
        </.row>
      </.rows>
    </.section>

    <.section title="Recent activity">
      <:hint><.link patch={Scope.path(@scope, :activity)} class="chip">see all ›</.link></:hint>
      <.rows empty={@activity == [] && "Nothing yet."}>
        <.row :for={a <- Enum.take(@activity, 5)} cols="66px 128px minmax(0,1fr) auto">
          <span class="dim">{Format.hhmm(a[:at])}</span>
          <span class="dim">{a[:actor]}</span>
          <span class="nm">{a[:action]} <span style="color:var(--accent)">{a[:target]}</span></span>
          <span class="dim">{a[:result]}</span>
        </.row>
      </.rows>
    </.section>
    """
  end

  # ==========================================================================
  # Ministry
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:ministry, :map, required: true)
  attr(:inbox, :list, default: [])

  def ministry(%{scope: %{tab: "raw"}} = assigns) do
    ~H"""
    <.raw
      term={Map.drop(@ministry, [:__struct__])}
      note="The registry record. Secrets appear as the NAMES of environment variables — the Cabinet never stores a value."
    />
    """
  end

  def ministry(%{scope: %{tab: "evidence"}} = assigns) do
    ~H"""
    <.section title="Why it is in this state">
      <.rows>
        <div style="padding:14px 16px">
          <.factor detail={Format.observed_at(@ministry)}>
            the Cabinet last saw it <b>{Format.box_state(@ministry)}</b>
          </.factor>
          <.factor detail={Format.live_at(@ministry)}>
            <%= if @ministry[:live] do %>
              it answered <code>/api/v1/health</code> with <b>{@ministry.live["status"]}</b>
            <% else %>
              it is not answering <code>/api/v1/health</code>
            <% end %>
          </.factor>
          <.factor detail={Format.sleeps_in(@ministry)}>idle-stop</.factor>
          <.factor detail={Format.cap_state(@ministry)}>cost cap</.factor>
        </div>
      </.rows>
    </.section>

    <.section title="Recent activations">
      <:hint>what its ruleset decided</:hint>
      <.rows empty={@inbox == [] && "No activations recorded for this ministry."}>
        <.row :for={e <- Enum.take(@inbox, 10)} cols="86px minmax(0,1fr) 130px 92px">
          <.pill>{e[:class]}</.pill>
          <span class="nm">{e[:summary]}</span>
          <span class="dim">{Format.decision_line(e)}</span>
          <span class="dim">{Format.hhmm(e[:inserted_at])}</span>
        </.row>
      </.rows>
    </.section>
    """
  end

  def ministry(assigns) do
    ~H"""
    <div :if={!@ministry[:instance_id]}>
      <.banner tone={:warn}>
        This ministry has no factory yet — the Cabinet knows its name and nothing to start.
      </.banner>
    </div>

    <.section :if={@ministry[:sectors] not in [nil, []]} title="Sectors">
      <:hint>what this factory works on</:hint>
      <.rows>
        <.row :for={s <- @ministry[:sectors] || []} cols="1.1fr minmax(0,1fr) auto">
          <.identity name={to_string(s)} />
          <span class="dim">browsable once the factory is awake</span>
          <.pill>asleep</.pill>
        </.row>
      </.rows>
    </.section>

    <.section title="Configuration">
      <:hint>how this ministry behaves, independent of what it works on</:hint>
      <.rows>
        <.row cols="1.1fr minmax(0,1fr) auto" to={Scope.path(@scope, :ruleset, ministry: @ministry.slug)}>
          <.identity name="Activation ruleset" id="what happens when something arrives" />
          <span class="dim">{Format.ruleset_summary(@ministry)}</span>
          <.pill tone={:ok}>in force</.pill>
        </.row>
        <.row cols="1.1fr minmax(0,1fr) auto">
          <.identity name="Mode" id="normal · vacation · off" />
          <span class="dim">changes which rules match, not which rules exist</span>
          <span class="seg">
            <button
              :for={mode <- ~w(normal vacation off)}
              phx-click="set_mode"
              phx-value-id={@ministry.id}
              phx-value-mode={mode}
              aria-current={if to_string(@ministry[:mode] || "normal") == mode, do: "true"}
            >{mode}</button>
          </span>
        </.row>
        <.row
          cols="1.1fr minmax(0,1fr) auto"
          to={Scope.path(@scope, :registration, ministry: @ministry.slug)}
        >
          <.identity name="Budget" id="month-to-date against a cap" />
          <span class="dim">{Format.cap_state(@ministry)}</span>
          <.pill tone={if @ministry[:cost_cap_usd], do: :ok, else: :warn}>
            {if @ministry[:cost_cap_usd], do: "capped", else: "no cap set"}
          </.pill>
        </.row>
        <.row
          cols="1.1fr minmax(0,1fr) auto"
          to={Scope.path(@scope, :registration, ministry: @ministry.slug)}
        >
          <.identity name="Registration" id="secrets by name only" />
          <span class="dim">/hooks/{@ministry.slug} · /relay/{@ministry.slug}</span>
          <.pill tone={if @ministry[:instance_id], do: :ok, else: :warn}>
            {if @ministry[:instance_id], do: "complete", else: "incomplete"}
          </.pill>
        </.row>
      </.rows>
    </.section>

    <.section title="Relations">
      <.relations>
        <:rel verb="governed by" to={Scope.path(@scope, :ruleset, ministry: @ministry.slug)}>
          Activation ruleset · {Format.ruleset_summary(@ministry)}
        </:rel>
        <:rel verb="receives">POST /hooks/{@ministry.slug}</:rel>
        <:rel verb="relays to">Discord · #{@ministry.slug}</:rel>
      </.relations>
    </.section>
    """
  end

  # ==========================================================================
  # Registration
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:ministry, :map, required: true)
  attr(:editing, :boolean, default: false)

  def registration(%{scope: %{tab: "raw"}} = assigns) do
    ~H"""
    <.raw
      term={Map.drop(@ministry, [:__struct__])}
      note="The registry record as stored. A leak of this leaks the NAMES of the secrets, which is the point of the design."
    />
    """
  end

  def registration(assigns) do
    ~H"""
    <form :if={@editing} phx-submit="save_ministry">
      <input :if={@ministry[:id]} type="hidden" name="ministry_id" value={@ministry[:id]} />
      <.reg_fields ministry={@ministry} editing={true} />
      <div style="display:flex;gap:8px;margin-top:14px">
        <button class="btn pri" type="submit">
          {if @ministry[:id], do: "Save registration", else: "Register ministry"}
        </button>
        <button class="btn" type="button" phx-click="cancel_edit">Cancel</button>
      </div>
    </form>
    <div :if={!@editing}>
      <.reg_fields ministry={@ministry} editing={false} />
      <div style="display:flex;gap:8px;margin-top:14px">
        <button class="btn" phx-click="edit" phx-value-id={@ministry[:id]}>Edit</button>
      </div>
    </div>
    """
  end

  attr(:ministry, :map, required: true)
  attr(:editing, :boolean, required: true)

  defp reg_fields(assigns) do
    ~H"""
    <.section title="Identity">
      <:hint>the slug is identity — retire and re-register to change it</:hint>
      <.rows>
        <.row cols="170px minmax(0,1fr) auto">
          <.identity name="Slug" id="path-safe, unique, permanent" />
          <span :if={@ministry[:id]} class="dim">{@ministry.slug}</span>
          <input :if={!@ministry[:id]} name="slug" value="" placeholder="home-affairs" required />
          <.pill :if={@ministry[:id]}>immutable</.pill>
        </.row>
        <.reg_field
          editing={@editing}
          name="name"
          label="Name"
          hint="what it is called on screen"
          value={@ministry[:name]}
          placeholder="Home Affairs"
        />
        <.reg_field
          editing={@editing}
          name="url"
          label="Factory URL"
          hint="where the Cabinet forwards and polls health"
          value={@ministry[:url]}
          placeholder="https://…"
        />
        <.reg_field
          editing={@editing}
          name="instance_id"
          label="Instance"
          hint="the EC2 instance the Cabinet may start and stop"
          value={@ministry[:instance_id]}
          placeholder="i-…"
        />
      </.rows>
    </.section>

    <.section title="Secrets">
      <:hint>by name only — the Cabinet never stores a value</:hint>
      <.rows>
        <.reg_field
          editing={@editing}
          name="webhook_secret_env"
          label="Webhook secret"
          hint="env var holding the secret GitHub signs with"
          value={@ministry[:webhook_secret_env]}
          placeholder="GITF_MIN_…_WEBHOOK_SECRET"
        />
        <.reg_field
          editing={@editing}
          name="api_key_env"
          label="API key"
          hint="env var holding this factory's API key"
          value={@ministry[:api_key_env]}
          placeholder="GITF_MIN_…_API_KEY"
        />
      </.rows>
      <p class="note" style="margin-top:8px">
        Both resolve from the Cabinet's environment at call time.
      </p>
    </.section>

    <.section title="Budget">
      <:hint>the cap the activation ruleset reads</:hint>
      <.rows>
        <.reg_field
          editing={@editing}
          name="cost_cap_usd"
          label="Monthly cap"
          hint="month-to-date above this turns every wake into a queue"
          value={@ministry[:cost_cap_usd]}
          placeholder="e.g. 40"
        />
        <.row cols="170px minmax(0,1fr) auto">
          <.identity name="Spent this month" id="from the factory's own ledger" />
          <span class="dim">{Format.spend_line(@ministry)}</span>
          <.pill tone={Format.cap_tone(@ministry)}>{Format.cap_state(@ministry)}</.pill>
        </.row>
      </.rows>
    </.section>
    """
  end

  attr(:editing, :boolean, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:placeholder, :string, default: nil)

  defp reg_field(assigns) do
    ~H"""
    <.row cols="170px minmax(0,1fr) auto">
      <.identity name={@label} id={@hint} />
      <input
        :if={@editing}
        name={@name}
        value={@value && to_string(@value)}
        placeholder={@placeholder}
      />
      <span :if={!@editing} class="dim">{(@value && to_string(@value)) || "—"}</span>
      <.pill :if={!@editing and is_nil(@value)} tone={:warn}>not set</.pill>
    </.row>
    """
  end

  # ==========================================================================
  # Ruleset — the grid and its coverage. The editor lands in the next phase.
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:ministry, :map, required: true)
  attr(:inbox, :list, default: [])

  def ruleset(%{scope: %{tab: "raw"}} = assigns) do
    ~H"""
    <.raw
      term={assigns.ministry[:rules] || JDM.default_rules()}
      note="The JDM document the grid reads. Simple mode and expert mode are two views of one thing."
    />
    """
  end

  def ruleset(%{scope: %{tab: "evidence"}} = assigns) do
    ~H"""
    <.section title="What it decided">
      <:hint>activations recorded for this ministry</:hint>
      <.rows empty={@inbox == [] && "No activations recorded yet."}>
        <.row :for={e <- Enum.take(@inbox, 20)} cols="86px minmax(0,1fr) 120px 92px">
          <.pill>{e[:class]}</.pill>
          <span class="nm">{e[:summary]}</span>
          <span class="dim">{Format.decision_line(e)}</span>
          <span class="dim">{Format.hhmm(e[:inserted_at])}</span>
        </.row>
      </.rows>
      <p class="note" style="margin-top:8px">
        A rule is an object with a history, not a line of configuration.
      </p>
    </.section>
    """
  end

  def ruleset(assigns) do
    assigns = assign(assigns, :rules, Format.rule_rows(assigns.ministry))

    ~H"""
    <.section title="Rules">
      <:hint>first hit wins · {length(@rules)} rules</:hint>
      <.rows empty={@rules == [] && "This ministry's ruleset cannot be read as a decision table."}>
        <.row :for={r <- @rules} cols="30px 1fr 1.2fr .8fr 92px">
          <span class="dim">{r.n}</span>
          <span class="nm">{r.class}</span>
          <span class="dim">{r.mode}</span>
          <span class="dim">{r.cap}</span>
          <.pill tone={Format.action_tone(r.action)}>{r.action}</.pill>
        </.row>
      </.rows>
      <p class="note" style="margin-top:8px">
        Wakes are gated by the monthly cap; anything the rules cannot decide queues — it never wakes.
      </p>
    </.section>
    """
  end

  # ==========================================================================
  # Activity
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:activity, :list, required: true)
  attr(:inbox, :list, required: true)
  attr(:filter, :string, default: "all")

  def activity(assigns) do
    ~H"""
    <.section title="Waiting on you">
      <:hint>queued activations — nothing here starts itself</:hint>
      <.rows empty={Format.queued(@inbox) == [] && "Nothing is waiting on you."}>
        <div :for={e <- Format.queued(@inbox)} class="row" style="grid-template-columns:86px minmax(0,1fr) 92px auto">
          <.pill>{e[:class]}</.pill>
          <.identity name={e[:summary]} id={"#{e[:ministry_slug]} · #{Format.decision_line(e)}"} />
          <span class="dim">{Format.hhmm(e[:inserted_at])}</span>
          <span style="display:inline-flex;gap:6px">
            <button class="btn pri sm" phx-click="start_entry" phx-value-id={e[:id]}>Start this</button>
            <button class="btn sm" phx-click="dismiss_entry" phx-value-id={e[:id]}>Dismiss</button>
          </span>
        </div>
      </.rows>
    </.section>

    <.section title="Activations">
      <:hint>
        <span class="seg">
          <button
            :for={{id, label} <- Format.inbox_filters()}
            phx-click="filter"
            phx-value-filter={id}
            aria-current={if @filter == id, do: "true"}
          >{label}</button>
        </span>
      </:hint>
      <.rows empty={Format.filter_inbox(@inbox, @filter) == [] && "Nothing here under “#{@filter}”."}>
        <.row
          :for={e <- Format.filter_inbox(@inbox, @filter)}
          cols="86px minmax(0,1fr) 130px 92px 110px"
        >
          <.pill>{e[:class]}</.pill>
          <.identity name={e[:summary]} id={e[:ministry_slug]} />
          <span class="dim">{Format.decision_line(e)}</span>
          <span class="dim">{Format.hhmm(e[:inserted_at])}</span>
          <.pill tone={Format.status_tone(e[:status])}>{e[:status]}</.pill>
        </.row>
      </.rows>
    </.section>

    <.section title="Acts">
      <:hint>actor · action · target · result</:hint>
      <.rows empty={@activity == [] && "Nothing yet."}>
        <.row :for={a <- @activity} cols="66px 140px minmax(0,1fr) auto">
          <span class="dim">{Format.hhmm(a[:at])}</span>
          <span class="dim">{a[:actor]}</span>
          <span class="nm">{a[:action]} <span style="color:var(--accent)">{a[:target]}</span></span>
          <span class="dim">{a[:result]}</span>
        </.row>
      </.rows>
    </.section>
    """
  end
end
