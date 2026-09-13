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

  alias GiTF.Cabinet.Ruleset
  alias GiTF.Dashboard.Console.{Events, Format, Scope}

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
  # Ruleset — the editor, its coverage, and what publishing would change
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:ministry, :map, required: true)
  attr(:inbox, :list, default: [])
  attr(:rules, :list, required: true)
  attr(:published, :list, required: true)
  attr(:draft?, :boolean, required: true)
  attr(:version, :integer, required: true)
  attr(:coverage, :map, required: true)
  attr(:diff, :list, required: true)
  attr(:replay, :map, required: true)
  attr(:editing_rule, :integer, default: -1)

  def ruleset(%{scope: %{tab: "raw"}} = assigns) do
    ~H"""
    <.raw
      term={Ruleset.to_jdm(@rules)}
      note={
        if @draft?,
          do: "The document the grid edits — showing your unsaved draft. Simple mode and expert mode are two views of one thing.",
          else: "The document the Gate is running. Simple mode and expert mode are two views of one thing."
      }
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
    </.section>

    <.section title="Rule usage">
      <:hint>published v{@version}</:hint>
      <.rows>
        <.row :for={{rule, i} <- Enum.with_index(@published)} cols="30px minmax(0,1fr) auto">
          <span class="dim">{i + 1}</span>
          <span class="sentence">{Phoenix.HTML.raw(Format.sentence(rule))}</span>
          <.pill tone={if Format.rule_fired(@inbox, i + 1) > 0, do: :ok, else: :warn}>
            {Format.fired_label(Format.rule_fired(@inbox, i + 1))}
          </.pill>
        </.row>
      </.rows>
      <p class="note" style="margin-top:8px">
        A rule is an object with a history, not a line of configuration. A rule that has never
        fired is not necessarily wrong — but it is worth knowing which ones carry the traffic.
      </p>
    </.section>
    """
  end

  def ruleset(assigns) do
    ~H"""
    <.banner :if={@draft?} tone={:acc}>
      You are editing a <b>draft</b>. The Cabinet is still running published
      <b>v{@version}</b> — nothing here takes effect until you publish it.
    </.banner>

    <.section title="Rules">
      <:hint>first hit wins · drag ⠿ to reorder · {length(@rules)} rules</:hint>
      <div class="rows" id="rules" phx-hook="RuleDrag">
        <div
          :for={{rule, i} <- Enum.with_index(@rules)}
          class={["rule", i + 1 in @coverage.dead && "dead"]}
          draggable="true"
          data-idx={i}
          id={"rule-#{i}"}
        >
          <div
            class="grip"
            tabindex="0"
            role="button"
            aria-label={"Reorder rule #{i + 1}. Use arrow keys."}
            phx-keydown="reorder_key"
            phx-value-index={i}
          >⠿</div>
          <div class="rn">{i + 1}</div>
          <div>
            <button style="width:100%" phx-click="edit_rule" phx-value-index={i}>
              <span class="sentence">{Phoenix.HTML.raw(Format.sentence(rule))}</span>
            </button>
            <.dead_rule :if={i + 1 in @coverage.dead} rules={@rules} index={i} />
            <.rule_editor :if={@editing_rule == i} rule={rule} index={i} />
          </div>
          <div class="ractions">
            <button class="iconbtn" phx-click="edit_rule" phx-value-index={i} title="Edit">✎</button>
          </div>
        </div>
      </div>
      <div style="display:flex;gap:8px;margin-top:10px;align-items:center">
        <button class="btn" phx-click="add_rule">+ Add a rule</button>
        <span class="note">
          A new rule lands above the last one, because the last one should be the catch-all.
        </span>
      </div>
    </.section>

    <.section title="Coverage">
      <:hint>
        {30 - length(@coverage.undecided)} of 30 decided ·
        {@coverage.tally["wake"] || 0} wake · {@coverage.tally["queue"] || 0} queue ·
        {@coverage.tally["drop"] || 0} drop
      </:hint>
      <.banner :if={@coverage.undecided != []} tone={:crit}>
        <b>{length(@coverage.undecided)} combinations are undecided.</b>
        The Cabinet queues what its rules cannot decide — it never wakes — but you should
        say so on purpose rather than by omission.
      </.banner>
      <.matrix coverage={@coverage} diff={@diff} />
      <p class="note" style="margin-top:8px">
        Every class × mode × cap the Cabinet can ever be asked about, and which rule decides it.{" "}
        <span :if={@diff != []} style="color:var(--accent)">Ringed cells differ from what is published.</span>
      </p>
    </.section>

    <.draft_bar :if={@draft?} diff={@diff} coverage={@coverage} version={@version} replay={@replay} />
    """
  end

  attr(:rules, :list, required: true)
  attr(:index, :integer, required: true)

  defp dead_rule(assigns) do
    assigns = assign(assigns, :shadowers, Ruleset.shadowers(assigns.rules, assigns.index))

    ~H"""
    <div class="banner warn" style="margin:8px 0 0">
      <.dot tone={:warn} />
      <span>
        This rule can never fire —
        <%= if length(@shadowers) == 1 do %>
          <b>rule {hd(@shadowers)}</b> already decides
        <% else %>
          rules <b>{Enum.join(@shadowers, ", ")}</b> already decide
        <% end %>
        every case it covers.
      </span>
      <button
        class="btn sm"
        style="margin-left:auto"
        phx-click="move_rule"
        phx-value-from={@index}
        phx-value-to={hd(@shadowers) - 1}
      >Move above rule {hd(@shadowers)}</button>
    </div>
    """
  end

  attr(:rule, :map, required: true)
  attr(:index, :integer, required: true)

  defp rule_editor(assigns) do
    ~H"""
    <div class="editor">
      <.chips label="Class" index={@index} field="class" selected={@rule.class} options={Ruleset.classes()} />
      <.chips label="Mode" index={@index} field="mode" selected={@rule.mode} options={Ruleset.modes()} />
      <%!-- Every value below rides on `phx-value-v`, never `phx-value-value`.
            LiveView's click extractor copies the element's native `el.value`
            into the params *after* the phx-value-* attributes, and a <button>
            with no value attribute reports "" — so `phx-value-value` always
            arrives empty. Every answer path on the Catwalk was broken that way
            until e5fd106. Do not rename it back. --%>
      <div class="fieldrow">
        <span class="lbl">Cost cap</span>
        <button
          :for={cap <- [:any, :under, :over]}
          class={["chip", @rule.cap == cap && "on"]}
          phx-click="set_rule"
          phx-value-index={@index}
          phx-value-field="cap"
          phx-value-v={cap}
        >{cap}</button>
      </div>
      <div class="fieldrow">
        <span class="lbl">Then</span>
        <button
          :for={action <- Ruleset.actions()}
          class={["chip", @rule.action == action && "on"]}
          phx-click="set_rule"
          phx-value-index={@index}
          phx-value-field="action"
          phx-value-v={action}
        >{action}</button>
      </div>
      <div style="display:flex;gap:8px;margin-top:10px">
        <button class="btn sm" phx-click="edit_rule" phx-value-index="-1">Done</button>
        <button class="btn sm" phx-click="duplicate_rule" phx-value-index={@index}>Duplicate</button>
        <button class="btn sm danger" phx-click="delete_rule" phx-value-index={@index}>Delete rule</button>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:field, :string, required: true)
  attr(:selected, :list, required: true)
  attr(:options, :list, required: true)

  defp chips(assigns) do
    ~H"""
    <div class="fieldrow">
      <span class="lbl">{@label}</span>
      <button
        class={["chip", @selected == [] && "on"]}
        phx-click="clear_rule_field"
        phx-value-index={@index}
        phx-value-field={@field}
      >any</button>
      <button
        :for={option <- @options}
        class={["chip", option in @selected && "on"]}
        phx-click="toggle_rule"
        phx-value-index={@index}
        phx-value-field={@field}
        phx-value-v={option}
      >{option}</button>
    </div>
    """
  end

  attr(:coverage, :map, required: true)
  attr(:diff, :list, default: [])

  defp matrix(assigns) do
    changed = MapSet.new(assigns.diff, &{&1.class, &1.mode, &1.cap})

    assigns =
      assign(assigns,
        changed: changed,
        by_key: Map.new(assigns.coverage.cells, &{{&1.class, &1.mode, &1.cap}, &1})
      )

    ~H"""
    <div class="matrix">
      <table class="mx">
        <thead>
          <tr>
            <th class="rowh" rowspan="2" style="vertical-align:bottom">class</th>
            <th :for={mode <- Ruleset.modes()} colspan="2">{mode}</th>
          </tr>
          <tr>
            <%= for _mode <- Ruleset.modes(), cap <- Ruleset.caps() do %>
              <th>{cap} cap</th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <tr :for={class <- Ruleset.classes()}>
            <th class="rowh">{class}</th>
            <%= for mode <- Ruleset.modes(), cap <- Ruleset.caps() do %>
              <% cell = @by_key[{class, mode, cap}] %>
              <td>
                <button
                  class={[
                    "cell",
                    cell.action || "none",
                    MapSet.member?(@changed, {class, mode, cap}) && "changed"
                  ]}
                  phx-click="trace"
                  phx-value-class={class}
                  phx-value-mode={mode}
                  phx-value-cap={cap}
                  title={if cell.rule, do: "decided by rule #{cell.rule}", else: "no rule matches"}
                >
                  {cell.action || "none"}<small>{if cell.rule, do: "rule #{cell.rule}", else: "—"}</small>
                </button>
              </td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:diff, :list, required: true)
  attr(:coverage, :map, required: true)
  attr(:version, :integer, required: true)
  attr(:replay, :map, required: true)

  defp draft_bar(assigns) do
    ~H"""
    <div class="draftbar">
      <div style="display:flex;align-items:center;gap:var(--s4);flex-wrap:wrap">
        <b style="font-size:14px">Draft from v{@version}</b>
        <.pill tone={:acc}>{length(@diff)} of 30 combinations change</.pill>
        <.pill :if={Ruleset.newly_waking(@diff) > 0} tone={:warn}>
          {Ruleset.newly_waking(@diff)} newly wake a factory
        </.pill>
        <.pill :if={@replay.changed != []} tone={:warn}>
          {length(@replay.changed)} past activations would differ
        </.pill>
        <.pill :if={@replay.changed == [] and @replay.total > 0} tone={:ok}>
          no past activation would differ
        </.pill>
        <span style="margin-left:auto;display:flex;gap:8px">
          <button class="btn" phx-click="discard_draft">Discard draft</button>
          <button class="btn pri" phx-click="publish" disabled={@coverage.undecided != []}>
            Publish v{@version + 1}
          </button>
        </span>
      </div>

      <div :if={@coverage.undecided != []} class="banner crit" style="margin:0">
        <.dot tone={:crit} />
        <span>Cannot publish while {length(@coverage.undecided)} combinations are undecided.</span>
      </div>

      <div :if={@diff != []} class="diffgrid">
        <div :for={d <- Enum.take(@diff, 8)} class="diffitem">
          <div class="k">{d.class} · {d.mode} · {d.cap} cap</div>
          <div class="v">
            <.pill tone={Format.action_tone(d.from)}>{d.from || "none"}</.pill>
            <span style="color:var(--ink-3)">→</span>
            <.pill tone={Format.action_tone(d.to)}>{d.to || "none"}</.pill>
            <span class="note" style="margin-left:auto">
              rule {d.from_rule || "—"} → {d.to_rule || "—"}
            </span>
          </div>
          <div :if={d.newly_wakes} class="note" style="margin-top:5px;color:var(--warn)">
            starts a factory and spends money without asking
          </div>
        </div>
        <div :if={length(@diff) > 8} class="diffitem">
          <div class="note">…and {length(@diff) - 8} more</div>
        </div>
      </div>
      <div :if={@diff == []} class="note">
        No combination changes — the rules read differently but behave identically.
      </div>

      <div :if={@replay.changed != []}>
        <div class="lbl" style="margin-bottom:7px">
          Replayed against the {@replay.total} activations this ministry has actually seen
        </div>
        <.rows>
          <.row :for={r <- Enum.take(@replay.changed, 6)} cols="minmax(0,1fr) auto">
            <.identity name={r.summary} id={"#{r.class} · #{r.mode} · #{r.cap} cap"} />
            <span style="display:flex;align-items:center;gap:7px">
              <.pill tone={Format.action_tone(r.was)}>{r.was || "none"}</.pill>
              <span style="color:var(--ink-3)">→</span>
              <.pill tone={Format.action_tone(r.would)}>{r.would || "none"}</.pill>
            </span>
          </.row>
        </.rows>
      </div>
    </div>
    """
  end

  # ==========================================================================
  # Activity
  # ==========================================================================

  attr(:scope, :map, required: true)
  attr(:events, :list, required: true)
  attr(:visible, :list, required: true)
  attr(:needs, :list, required: true)
  attr(:filters, :map, required: true)
  attr(:needs_open, :boolean, default: true)
  attr(:needs_config_open, :boolean, default: false)
  attr(:needs_kinds, :list, required: true)

  def activity(assigns) do
    ~H"""
    <details open={@needs_open} id="needs-section" phx-hook="NeedsToggle">
      <summary>
        <div class="dsum">
          <.dot tone={if @needs == [], do: :ok, else: :warn} />
          <span>
            {if @needs == [],
              do: "Nothing needs a person",
              else: "#{length(@needs)} #{if length(@needs) == 1, do: "thing needs", else: "things need"} a person"}
          </span>
          <span class="note">
            {if @needs == [],
              do: "— the Cabinet is running unattended",
              else: "— nothing here resolves itself"}
          </span>
          <span style="margin-left:auto;display:flex;gap:8px;align-items:center">
            <span class="btn sm" phx-click="toggle_needs_config">What counts? ▾</span>
          </span>
        </div>
      </summary>

      <div class="rows" style="border-radius:0 0 var(--r2) var(--r2)">
        <div :if={@needs == []} class="empty">
          Nothing is waiting on you. Queued activations and deliveries the Cabinet
          could not hand over would appear here.
        </div>
        <div :for={e <- @needs} class="needs">
          <.dot tone={e.tone || :warn} />
          <span>
            <span class="nm">{e.needs.what}</span>
            <br /><span class="note">{e.target}</span>
          </span>
          <span class="note">{e.ministry} · {e.detail}</span>
          <span class="dim">{Format.ago(e.at)} ago</span>
          <span style="display:inline-flex;gap:6px">
            <button class="btn pri sm" phx-click="start_entry" phx-value-id={e.id}>{e.needs.act}</button>
            <button :if={e.needs.dismissable} class="btn sm" phx-click="dismiss_entry" phx-value-id={e.id}>
              Dismiss
            </button>
          </span>
        </div>
      </div>

      <div
        :if={@needs_config_open}
        style="border:1px solid var(--line);border-top:0;border-radius:0 0 var(--r2) var(--r2);padding:var(--s4);background:var(--stage)"
      >
        <div class="lbl" style="margin-bottom:8px">Surface an event here when its kind is</div>
        <div style="display:flex;gap:6px;flex-wrap:wrap">
          <button
            :for={{kind, label} <- Events.kinds()}
            class={["chip", to_string(kind) in @needs_kinds && "on"]}
            phx-click="toggle_needs_kind"
            phx-value-kind={kind}
          >{label}</button>
        </div>
        <p class="note" style="margin:9px 0 0">
          A small, inspectable policy rather than a hard-coded list — the same shape as the
          activation ruleset. An event only appears if it is <em>also</em> unresolved: turning a
          kind on cannot surface something the Cabinet has already dealt with.
        </p>
      </div>
    </details>

    <div style="height:var(--s5)"></div>

    <.section title="Log">
      <:hint>
        {length(@visible)} of {length(@events)} events
        <span :if={Events.active_count(@filters) > 0}>
          · <button class="chip" phx-click="clear_filters">clear {Events.active_count(@filters)} filters</button>
        </span>
        · <button class="chip" phx-click="save_investigation">save as investigation</button>
      </:hint>

      <div :if={@visible == []}>
        <.rows empty="No events match these filters."></.rows>
      </div>

      <div :for={{day, rows} <- Format.by_day(@visible)} style="margin-bottom:var(--s4)">
        <div class="lbl" style="margin-bottom:6px">{day}</div>
        <.rows>
          <.row
            :for={e <- rows}
            cols="60px 104px 168px minmax(0,1fr) 112px"
            to={e.to}
          >
            <span class="dim">{Format.hhmm(e.at)}</span>
            <span><.pill>{Events.kind_label(e.kind)}</.pill></span>
            <span class="dim">{e.actor}</span>
            <span>
              <span class="nm">{e.what} <span style="color:var(--accent)">{e.target}</span></span>
              <br :if={e.detail} /><span :if={e.detail} class="note">{e.detail}</span>
            </span>
            <span style="justify-self:end"><.pill tone={e.tone}>{e.result}</.pill></span>
          </.row>
        </.rows>
      </div>

      <p class="note" style="margin-top:6px">
        Activations and acts in one stream: a bug arrives, a rule wakes a factory, a person holds it
        awake. Told across two screens it had to be reassembled by eye.
      </p>
    </.section>
    """
  end

  attr(:events, :list, required: true)
  attr(:filters, :map, required: true)
  attr(:investigations, :list, default: [])

  def facets(assigns) do
    ~H"""
    <aside class="pane facets" aria-label="Filters">
      <div class="facet">
        <h4>Search</h4>
        <form phx-change="search" phx-submit="search">
          <input name="q" value={@filters.q} placeholder="in any field…" style="width:100%" phx-debounce="250" />
        </form>
      </div>
      <div class="fsep"></div>

      <div class="facet">
        <h4>When</h4>
        <button
          :for={{id, label, count} <- Events.window_counts(@events, @filters)}
          class={["fopt", count == 0 && "zero"]}
          aria-pressed={to_string(@filters.when == id)}
          phx-click="set_window"
          phx-value-window={id}
        >
          <span class="box">{if @filters.when == id, do: "✓"}</span>
          <span>{label}</span>
          <span class="n">{count}</span>
        </button>
      </div>
      <div class="fsep"></div>

      <.facet_group events={@events} filters={@filters} field={:kind} title="Event kind" />
      <div class="fsep"></div>
      <.facet_group events={@events} filters={@filters} field={:ministry} title="Ministry" />
      <div class="fsep"></div>
      <.facet_group events={@events} filters={@filters} field={:actor} title="Actor" />
      <div class="fsep"></div>
      <.facet_group events={@events} filters={@filters} field={:result} title="Result" />

      <div class="fsep"></div>
      <div class="facet">
        <h4>Sector</h4>
        <p class="note" style="margin:0">
          Sectors live on the factory, not the Cabinet — a control here could only ever be empty.
          It arrives with the rest of the tree.
        </p>
      </div>

      <div :if={@investigations != []} class="fsep"></div>
      <div :if={@investigations != []} class="facet">
        <h4>Investigations</h4>
        <div :for={inv <- @investigations} style="display:flex;align-items:center;gap:6px">
          <.link patch={inv.path} class="fopt" style="flex:1">
            <span class="box">⌕</span><span>{inv.name}</span>
          </.link>
          <button class="iconbtn" phx-click="delete_investigation" phx-value-id={inv.id} title="Forget this">
            ✕
          </button>
        </div>
      </div>
    </aside>
    """
  end

  attr(:events, :list, required: true)
  attr(:filters, :map, required: true)
  attr(:field, :atom, required: true)
  attr(:title, :string, required: true)

  defp facet_group(assigns) do
    assigns =
      assign(assigns, :options, Events.facet(assigns.events, assigns.filters, assigns.field))

    ~H"""
    <div class="facet">
      <h4>
        {@title}
        <button
          :if={Map.get(@filters, @field) != []}
          class="clr"
          phx-click="clear_facet"
          phx-value-field={@field}
        >clear</button>
      </h4>
      <p :if={@options == []} class="note" style="margin:0">nothing recorded yet</p>
      <button
        :for={{value, label, count} <- @options}
        class={["fopt", count == 0 && "zero"]}
        aria-pressed={to_string(to_string(value) in Map.get(@filters, @field))}
        phx-click="toggle_facet"
        phx-value-field={@field}
        phx-value-v={value}
      >
        <span class="box">{if to_string(value) in Map.get(@filters, @field), do: "✓"}</span>
        <span>{label}</span>
        <span class="n">{count}</span>
      </button>
    </div>
    """
  end
end
