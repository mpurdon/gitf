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

  def inquiry_card(assigns) do
    ~H"""
    <div class="panel" style={"margin-bottom:0.75rem; border-left:3px solid #{if @inquiry[:status] == "open", do: "#d29922", else: "#3fb950"}"}>
      <div style="display:flex; justify-content:space-between; align-items:baseline; gap:1rem; flex-wrap:wrap">
        <div style="min-width:0; flex:1">
          <div style="display:flex; gap:0.4rem; align-items:baseline; flex-wrap:wrap; margin-bottom:0.35rem">
            <span class="badge badge-grey">{@inquiry[:phase]}</span>
            <span class="badge badge-grey" style="font-family:monospace">{@inquiry[:key]}</span>
            <span class="badge badge-grey">{@inquiry[:kind]}</span>
            <a
              :if={@mission_link and @inquiry[:mission_id]}
              href={"/dashboard/missions/#{@inquiry.mission_id}"}
              style="font-family:monospace; font-size:0.75rem; color:#58a6ff; text-decoration:none"
            >{@inquiry.mission_id}</a>
            <%!-- An inherited answer was never put to a human on THIS run.
                  Saying so stops it reading as attention already spent here. --%>
            <span :if={@inquiry[:inherited_from]} class="badge badge-blue" title={"Answered on #{@inquiry.inherited_from} and inherited across a resume"}>
              inherited
            </span>
          </div>
          <div style="font-size:0.95rem; color:#f0f6fc; white-space:pre-wrap">{@inquiry[:prompt]}</div>
        </div>
        <div style="font-size:0.7rem; color:#6b7280; white-space:nowrap">
          asked {format_timestamp(@inquiry[:asked_at])}
        </div>
      </div>

      <%= if @inquiry[:status] == "answered" do %>
        <div style="margin-top:0.7rem; font-size:0.85rem; color:#c9d1d9">
          <span class="badge badge-green">answered</span>
          <b style="margin-left:0.4rem">{@inquiry[:answer_label] || @inquiry[:answer]}</b>
          <span style="color:#8b949e">
            — {@inquiry[:answered_by]}{if @inquiry[:answered_at], do: ", #{format_timestamp(@inquiry[:answered_at])}"}
          </span>
        </div>
      <% else %>
        <div style="margin-top:0.8rem">
          <.answer_controls inquiry={@inquiry} draft={@draft} />
        </div>
      <% end %>
    </div>
    """
  end

  attr(:inquiry, :map, required: true)
  attr(:draft, :string, default: nil)

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

  defp answer_controls(%{inquiry: %{kind: :confirm}} = assigns) do
    ~H"""
    <div class="action-bar" style="justify-content:flex-start">
      <button phx-click="answer_inquiry" phx-value-id={@inquiry.id} phx-value-value="true" class="btn btn-green">Yes</button>
      <button phx-click="answer_inquiry" phx-value-id={@inquiry.id} phx-value-value="false" class="btn btn-red">No</button>
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
        phx-value-value={option.id}
        class="btn btn-grey"
        style="text-align:left; display:block; width:100%; padding:0.5rem; white-space:normal"
      >
        <%!-- The frame carries its own fallback text. A broken or pruned
              image hides itself and the text underneath becomes visible,
              so the tile degrades to a labelled option in place. --%>
        <div style="position:relative; background:#0d1117; border:1px solid #30363d; border-radius:4px; aspect-ratio:16/10; overflow:hidden; display:flex; align-items:center; justify-content:center">
          <span style="position:absolute; font-size:0.7rem; color:#6b7280; padding:0 0.5rem; text-align:center">
            {option[:preview_error] || "no preview"}
          </span>
          <img
            :if={Preview.url(@inquiry, option)}
            src={Preview.url(@inquiry, option)}
            alt={"Mockup of #{option.label}"}
            loading="lazy"
            onerror="this.style.display='none'"
            style="position:relative; width:100%; height:100%; object-fit:contain; background:#0d1117"
          />
        </div>
        <div style="font-weight:600; color:#f0f6fc; margin-top:0.45rem">{option.label}</div>
        <div :if={option[:rationale]} style="font-size:0.78rem; color:#8b949e; margin-top:0.2rem">
          {option.rationale}
        </div>
      </button>
    </div>
    """
  end

  # The rationale is not decoration. It is the whole reason a choice can
  # be answered in ten seconds from a phone: the operator has to be able
  # to judge between the options without opening the code.
  defp text_choice(assigns) do
    ~H"""
    <div style="display:flex; flex-direction:column; gap:0.5rem">
      <button
        :for={option <- @inquiry[:options] || []}
        phx-click="answer_inquiry"
        phx-value-id={@inquiry.id}
        phx-value-value={option.id}
        class="btn btn-grey"
        style="text-align:left; display:block; width:100%; padding:0.6rem 0.75rem; white-space:normal"
      >
        <div style="font-weight:600; color:#f0f6fc">{option.label}</div>
        <div :if={option[:rationale]} style="font-size:0.78rem; color:#8b949e; margin-top:0.2rem">
          {option.rationale}
        </div>
      </button>
    </div>
    """
  end
end
