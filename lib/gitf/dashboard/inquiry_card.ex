defmodule GiTF.Dashboard.InquiryCard do
  @moduledoc """
  The one rendering of an operator question, shared by the Questions
  queue and the mission detail page.

  Two surfaces, one component, for the same reason `GiTF.Approval.Triage`
  is one module: a question that reads differently depending on which
  page you found it on is a question the operator answers differently
  depending on which page they found it on. The queue and the mission
  page differ in what surrounds the card — a mission link on one, the
  pipeline on the other — never in the decision itself.

  Both hosts must implement two events:

    * `"answer_inquiry"` with `id` and (for `:choice` / `:confirm`) `value`
    * `"draft_answer"` with `id` and `value`, for the `:text` box

  The card is deliberately plain — a list of labelled options with their
  rationale, or a text field — with ONE exception, and it is the reason
  the gate is worth having for design work at all.

  ## The mockup grid

  A `:choice` whose options carry `option.preview` renders as a grid of
  images instead of a list of buttons, because a visual decision asked in
  prose is a decision the operator has to imagine before they can make
  it. `GiTF.Inquiry.Preview` renders every option at the SAME fixed
  viewport, and the grid lays them out at the same size for the same
  reason: the operator is comparing designs, and any difference in
  framing between the tiles is noise they will read as signal.

  The image never replaces the label and the rationale — it sits above
  them. A preview can fail to render (`preview_error`), and it can be
  pruned out from under an old answered question by
  `GiTF.Inquiry.Preview.prune/0`, so every tile stays answerable with the
  picture missing. The `onerror` handler folds a broken image away and
  reveals the frame's own "preview unavailable" text underneath, which is
  what a pruned preview on an inherited answer looks like: a question the
  operator can still read, not a broken card.
  """

  use Phoenix.Component

  import GiTF.Dashboard.Helpers

  alias GiTF.Inquiry.Preview

  attr(:inquiry, :map, required: true)
  attr(:draft, :string, default: nil)
  attr(:mission_link, :boolean, default: false)
  # Per-option votes the operator has clicked so far (option id → vote),
  # held by the hosting LiveView until the rejection is submitted.
  attr(:votes, :map, default: %{})

  def inquiry_card(assigns) do
    ~H"""
    <div class="panel" style={"margin-bottom:0.75rem; border-left:3px solid #{if @inquiry[:status] == "open", do: "var(--warn)", else: "var(--ok)"}"}>
      <div style="display:flex; justify-content:space-between; align-items:baseline; gap:1rem; flex-wrap:wrap">
        <div style="min-width:0; flex:1">
          <div style="display:flex; gap:0.4rem; align-items:baseline; flex-wrap:wrap; margin-bottom:0.35rem">
            <span class="badge badge-grey">{@inquiry[:phase]}</span>
            <span class="badge badge-grey" style="font-family:monospace">{@inquiry[:key]}</span>
            <span class="badge badge-grey">{@inquiry[:kind]}</span>
            <a
              :if={@mission_link and @inquiry[:mission_id]}
              href={"/dashboard/missions/#{@inquiry.mission_id}"}
              style="font-family:monospace; font-size:0.75rem; color:var(--accent); text-decoration:none"
            >{@inquiry.mission_id}</a>
            <%!-- An inherited answer was never put to a human on THIS run.
                  Saying so stops it reading as attention already spent here. --%>
            <span :if={@inquiry[:inherited_from]} class="badge badge-blue" title={"Answered on #{@inquiry.inherited_from} and inherited across a resume"}>
              inherited
            </span>
          </div>
          <div style="font-size:0.95rem; color:var(--text); white-space:pre-wrap">{@inquiry[:prompt]}</div>
        </div>
        <div style="font-size:0.7rem; color:var(--muted); white-space:nowrap">
          asked {format_timestamp(@inquiry[:asked_at])}
        </div>
      </div>

      <%= if @inquiry[:status] == "answered" do %>
        <div style="margin-top:0.7rem; font-size:0.85rem; color:var(--text-2)">
          <span class={"badge #{if @inquiry[:outcome] == "rejected", do: "badge-orange", else: "badge-green"}"}>
            {if @inquiry[:outcome] == "rejected", do: "rejected", else: "answered"}
          </span>
          <b style="margin-left:0.4rem">{@inquiry[:answer_label] || @inquiry[:answer]}</b>
          <span style="color:var(--muted)">
            — {@inquiry[:answered_by]}{if @inquiry[:answered_at], do: ", #{format_timestamp(@inquiry[:answered_at])}"}
          </span>
          <div :if={@inquiry[:direction]} style="margin-top:0.3rem; color:var(--muted); font-style:italic">
            direction: {@inquiry[:direction]}
          </div>
        </div>
      <% else %>
        <div style="margin-top:0.8rem">
          <.answer_controls inquiry={@inquiry} draft={@draft} votes={@votes} />
        </div>
        <.redesign_controls :if={@inquiry[:kind] == :choice} inquiry={@inquiry} votes={@votes} />
      <% end %>
    </div>
    """
  end

  attr(:inquiry, :map, required: true)
  attr(:draft, :string, default: nil)
  attr(:votes, :map, default: %{})

  # The grid arm is chosen on whether any option ACTUALLY has an image,
  # not on whether one was asked for. A question whose mockups all failed
  # to render must fall back to the plain list rather than draw a grid of
  # empty frames — the operator loses the pictures either way, and a list
  # of labelled options is the better thing to be left with.
  defp answer_controls(%{inquiry: %{kind: :choice, options: options}} = assigns)
       when is_list(options) do
    if Enum.any?(options, &(&1[:preview] != nil)) do
      preview_choice(assigns)
    else
      text_choice(assigns)
    end
  end

  defp answer_controls(%{inquiry: %{kind: :choice}} = assigns), do: text_choice(assigns)

  # The answer rides on `phx-value-answer`, NOT `phx-value-value`.
  # phoenix_live_view's click extractor copies the element's native
  # `el.value` into the params after the phx-value-* attributes, and a
  # <button> without a value attribute reports "" — so `phx-value-value`
  # always reached the server as "". Every answer path on the Catwalk was
  # broken that way until inq-acd882 (2026-08-31). Do not rename it back.
  defp answer_controls(%{inquiry: %{kind: :confirm}} = assigns) do
    ~H"""
    <div class="action-bar" style="justify-content:flex-start">
      <button phx-click="answer_inquiry" phx-value-id={@inquiry.id} phx-value-answer="true" class="btn btn-green">Yes</button>
      <button phx-click="answer_inquiry" phx-value-id={@inquiry.id} phx-value-answer="false" class="btn btn-red">No</button>
    </div>
    """
  end

  defp answer_controls(%{inquiry: %{kind: :text}} = assigns) do
    ~H"""
    <div class="form-group" style="margin-bottom:0.5rem">
      <textarea
        id={"answer-#{@inquiry.id}"}
        class="form-textarea"
        name="value"
        phx-change="draft_answer"
        phx-value-id={@inquiry.id}
        phx-debounce="300"
        style="min-height:60px"
      ><%= @draft %></textarea>
    </div>
    <div class="action-bar" style="justify-content:flex-start">
      <button phx-click="answer_inquiry" phx-value-id={@inquiry.id} class="btn btn-green">Answer</button>
    </div>
    """
  end

  # A kind nothing knows how to render must not silently show a card with
  # no way to answer it — that is a mission held on an unanswerable
  # question, which is the exact outcome `Inquiry.validate/1` exists to
  # prevent. Say what happened instead.
  defp answer_controls(assigns) do
    ~H"""
    <div class="triage-warn">
      Unrecognised question kind {inspect(@inquiry[:kind])} — this cannot be answered from the
      Catwalk. Answer it over the MCP (<code>answer_question</code>) or kill the mission.
    </div>
    """
  end

  defp preview_choice(assigns) do
    ~H"""
    <div style="display:grid; grid-template-columns:repeat(auto-fit, minmax(260px, 1fr)); gap:0.75rem">
      <button
        :for={option <- @inquiry[:options] || []}
        phx-click="answer_inquiry"
        phx-value-id={@inquiry.id}
        phx-value-answer={option.id}
        class="btn btn-grey"
        style="text-align:left; display:block; width:100%; padding:0.5rem; white-space:normal"
      >
        <%!-- The frame carries its own fallback text. A broken or pruned
              image hides itself and the text underneath becomes visible,
              so the tile degrades to a labelled option in place. --%>
        <div style="position:relative; background:var(--ground); border:1px solid var(--line); border-radius:4px; aspect-ratio:16/10; overflow:hidden; display:flex; align-items:center; justify-content:center">
          <span style="position:absolute; font-size:0.7rem; color:var(--muted); padding:0 0.5rem; text-align:center">
            {option[:preview_error] || "no preview"}
          </span>
          <img
            :if={Preview.url(@inquiry, option)}
            src={Preview.url(@inquiry, option)}
            alt={"Mockup of #{option.label}"}
            loading="lazy"
            onerror="this.style.display='none'"
            style="position:relative; width:100%; height:100%; object-fit:contain; background:var(--ground)"
          />
        </div>
        <div style="font-weight:600; color:var(--text); margin-top:0.45rem">{option.label}</div>
        <div :if={option[:rationale]} style="font-size:0.78rem; color:var(--muted); margin-top:0.2rem">
          {option.rationale}
        </div>
      </button>
    </div>
    <.vote_row inquiry={@inquiry} votes={@votes} />
    """
  end

  # One thumbs-up / thumbs-down / neutral toggle per option. Votes are not
  # an answer: they steer the NEXT round when the operator rejects all of
  # these, so they sit outside the option buttons and only mean something
  # once "none of these" is submitted.
  attr(:inquiry, :map, required: true)
  attr(:votes, :map, default: %{})

  defp vote_row(assigns) do
    ~H"""
    <div style="display:flex; gap:1rem; flex-wrap:wrap; margin-top:0.5rem; font-size:0.78rem; color:var(--muted)">
      <div :for={option <- @inquiry[:options] || []} style="display:flex; align-items:center; gap:0.3rem">
        <span style="max-width:14rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap">{option.label}</span>
        <button
          :for={{vote, glyph, title} <- [{"up", "👍", "keep this direction"}, {"neutral", "➖", "no signal"}, {"down", "👎", "do not re-offer"}]}
          phx-click="vote_inquiry"
          phx-value-id={@inquiry.id}
          phx-value-option={option.id}
          phx-value-vote={vote}
          title={title}
          aria-pressed={to_string(Map.get(@votes, option.id, "neutral") == vote)}
          class="btn btn-grey"
          style={"padding:0.1rem 0.45rem; font-size:0.85rem; #{if Map.get(@votes, option.id, "neutral") == vote, do: "border-color:var(--accent); color:var(--text)", else: "opacity:0.6"}"}
        >{glyph}</button>
      </div>
    </div>
    """
  end

  # "None of these." A rejection is an answer that sends the phase back to
  # propose again, carrying the votes above and the direction typed here.
  attr(:inquiry, :map, required: true)
  attr(:votes, :map, default: %{})

  defp redesign_controls(assigns) do
    ~H"""
    <form phx-submit="reject_inquiry" style="margin-top:0.9rem; border-top:1px dashed var(--line); padding-top:0.7rem">
      <input type="hidden" name="inquiry_id" value={@inquiry.id} />
      <div style="font-size:0.8rem; color:var(--muted); margin-bottom:0.35rem">
        None of these? Vote on each above, say where to go instead, and send the phase back for another round.
      </div>
      <div style="display:flex; gap:0.5rem; align-items:flex-start; flex-wrap:wrap">
        <textarea
          name="direction"
          rows="2"
          placeholder="Optional direction — e.g. lighter than the band, but a clearer boundary than the hairline"
          style="flex:1; min-width:16rem; background:var(--ground); border:1px solid var(--line); border-radius:4px; color:var(--text); font-size:0.82rem; padding:0.4rem 0.5rem"
        ></textarea>
        <button type="submit" class="btn btn-red" style="white-space:nowrap">None of these — redesign</button>
      </div>
    </form>
    """
  end

  # The rationale is not decoration. It is the whole reason a choice can
  # be answered in ten seconds from a phone: the operator has to be able
  # to judge between the options without opening the code.
  # A list arm reached because every mockup failed to render must say so:
  # "no mockup was attempted" and "three were made and the renderer broke"
  # are different facts, and only the second is a factory defect to fix.
  # msn-629e74 asked its design question with all three previews dead
  # (Playwright's browser missing on a replaced box) and the page showed a
  # plain list with no hint anything had gone wrong.
  defp text_choice(assigns) do
    assigns = assign(assigns, :preview_failures, preview_failures(assigns.inquiry))

    ~H"""
    <div :if={@preview_failures != []} class="triage-warn" style="font-size:0.78rem">
      Mockups were produced for these options but failed to render:
      <span :for={reason <- @preview_failures} style="display:block; font-family:monospace; margin-top:0.2rem">
        {reason}
      </span>
    </div>
    <div style="display:flex; flex-direction:column; gap:0.5rem">
      <button
        :for={option <- @inquiry[:options] || []}
        phx-click="answer_inquiry"
        phx-value-id={@inquiry.id}
        phx-value-answer={option.id}
        class="btn btn-grey"
        style="text-align:left; display:block; width:100%; padding:0.6rem 0.75rem; white-space:normal"
      >
        <div style="font-weight:600; color:var(--text)">{option.label}</div>
        <div :if={option[:rationale]} style="font-size:0.78rem; color:var(--muted); margin-top:0.2rem">
          {option.rationale}
        </div>
      </button>
    </div>
    <.vote_row inquiry={@inquiry} votes={@votes} />
    """
  end

  @doc """
  The rejection, for a hosting LiveView's `reject_inquiry` event: records
  it with the votes the page collected and returns the flash to show.
  Shared by the Questions queue and the mission page so the two cannot
  drift on what a rejection means.
  """
  @spec reject(String.t(), map(), String.t() | nil, String.t()) :: {:info | :error, String.t()}
  def reject(id, votes, direction, actor) do
    case GiTF.Inquiry.reject(id, %{votes: votes, direction: direction}, answered_by: actor) do
      {:ok, inquiry, :answered} ->
        GiTF.AuditLog.record(actor, "inquiry.reject", inquiry.mission_id, %{
          inquiry_id: id,
          key: inquiry[:key],
          votes: votes,
          direction: direction
        })

        {:info,
         "Rejected. #{inquiry.mission_id} re-runs #{inquiry[:phase]} with your votes and direction " <>
           "on the next sweep."}

      {:ok, inquiry, :already_answered} ->
        {:info,
         "Already answered (#{inquiry[:answer_label] || inquiry[:answer]}) by " <>
           "#{inquiry[:answered_by]}. The first answer stands."}

      {:error, {:invalid, reason}} ->
        {:error, "Cannot reject: #{reason}"}

      {:error, :not_found} ->
        {:error, "That question no longer exists."}
    end
  end

  # Distinct failure reasons across the options, first line of each.
  defp preview_failures(inquiry) do
    (inquiry[:options] || [])
    |> Enum.map(& &1[:preview_error])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.split("\n") |> hd()))
    |> Enum.uniq()
  end
end
