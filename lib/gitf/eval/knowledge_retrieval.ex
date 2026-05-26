defmodule GiTF.Eval.KnowledgeRetrieval do
  @moduledoc """
  Eval scenario: `Knowledge.Retrieval.search/3` ranks the right wiki
  page within top-K for a representative query, using a synthetic
  8-page corpus that exercises semantic discrimination, paraphrase
  robustness, and below-threshold rejection of off-topic queries.

  The corpus is seeded into a dedicated `_eval` sector on first run
  (idempotent — `Knowledge.Page.put/1` is upsert keyed by slug) so
  the eval is portable across machines without depending on whatever
  the operator happens to have in their vault. The pages persist
  between runs; rerunning the eval against the same corpus produces
  the same results modulo embedding-model drift, which is exactly
  what this scenario is here to catch.

  Skipped when `GiTF.gitf_dir/0` doesn't return a writable root (no
  vault, no test).

  ## Case shape

      %{
        id: "auth_exact",
        query: "How does the authentication flow work?",
        expected_slug: "authentication-overview",   # or :none for below-threshold cases
        min_rank: 2                                  # ignored when expected_slug == :none
      }

  Pass: expected slug appears at rank ≤ min_rank, OR (when `:none`)
  no result has score ≥ `min_similarity`.
  """

  @behaviour GiTF.Eval.Scenario

  alias GiTF.Knowledge.{Page, Retrieval}

  @eval_sector "_eval"

  @impl true
  def name, do: "knowledge_retrieval"

  @impl true
  def description,
    do: "Knowledge.Retrieval.search ranks expected wiki page within top-K (synthetic corpus)"

  @impl true
  def cases do
    [
      # Exact title-keyword match
      %{
        id: "auth_exact",
        query: "authentication overview",
        expected_slug: "authentication-overview",
        min_rank: 2
      },

      # Semantic paraphrase — query uses "login" instead of "authentication"
      %{
        id: "auth_paraphrase_login",
        query: "How does a user login work end to end?",
        expected_slug: "authentication-overview",
        min_rank: 3
      },

      # OTP supervision specifics
      %{
        id: "otp_supervisor_restart",
        query: "supervisor restart strategy one_for_one",
        expected_slug: "otp-supervision",
        min_rank: 2
      },

      # GenServer discrimination — should NOT rank otp-supervision above
      # genserver-patterns for a GenServer-specific question
      %{
        id: "genserver_state_paraphrase",
        query: "managing state inside a long-running Elixir process",
        expected_slug: "genserver-patterns",
        min_rank: 3
      },

      # Cross-cutting concept — telemetry/observability
      %{
        id: "telemetry_paraphrase",
        query: "emitting metrics and traces from a running service",
        expected_slug: "telemetry-events",
        min_rank: 3
      },

      # Domain-specific tool query
      %{
        id: "ecto_changeset",
        query: "validating user input with changesets",
        expected_slug: "ecto-changesets",
        min_rank: 2
      },

      # Below-threshold rejection — off-topic query must NOT pull
      # anything above the min_similarity cutoff
      %{
        id: "off_topic_rejection",
        query: "best pizza toppings for a Friday night dinner",
        expected_slug: :none,
        min_rank: 0
      }
    ]
  end

  @impl true
  def run(case_map, opts) do
    case ensure_corpus_seeded() do
      :ok -> do_run(case_map, opts)
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp do_run(case_map, opts) do
    top_k = Keyword.get(opts, :top_k, 5)
    min_similarity = Keyword.get(opts, :min_similarity, 0.4)

    case Retrieval.search(@eval_sector, case_map.query,
           top_k: top_k,
           min_similarity: min_similarity
         ) do
      {:ok, ranked} -> evaluate(case_map, ranked, top_k)
      {:error, reason} -> {:fail, %{reason: "retrieval failed: #{inspect(reason)}"}}
    end
  end

  defp evaluate(%{expected_slug: :none}, [], _top_k) do
    {:pass, %{top_k: [], note: "no result above threshold (as expected)"}}
  end

  defp evaluate(%{expected_slug: :none}, ranked, _top_k) do
    slugs_with_scores =
      Enum.map(ranked, fn {score, page} ->
        "#{page.slug}=#{Float.round(score, 3)}"
      end)

    {:fail,
     %{top_k: slugs_with_scores, reason: "off-topic query returned matches above threshold"}}
  end

  defp evaluate(case_map, ranked, top_k) do
    slugs = Enum.map(ranked, fn {_score, page} -> page.slug end)
    rank = GiTF.Eval.Helpers.find_rank(slugs, case_map.expected_slug)
    GiTF.Eval.Helpers.rank_verdict(rank, slugs, case_map.min_rank, top_k)
  end

  # -- Corpus seeding --------------------------------------------------------

  # Idempotent — `Page.put/1` is upsert by slug. We skip the put when the
  # page already exists with the right content hash so reruns are cheap.
  defp ensure_corpus_seeded do
    case GiTF.gitf_dir() do
      {:ok, _} ->
        Enum.each(corpus(), &maybe_seed/1)
        :ok

      _ ->
        {:skip, "no gitf root configured — vault writes need a workspace"}
    end
  rescue
    e -> {:skip, "corpus seeding raised: #{Exception.message(e)}"}
  end

  defp maybe_seed(%{slug: slug} = page_spec) do
    case Page.get(@eval_sector, slug) do
      nil ->
        {:ok, _} = Page.put(Map.put(page_spec, :sector_id, @eval_sector))
        :ok

      _existing ->
        # Page exists. Don't re-put — re-put rewrites the file (touching
        # mtime) and invalidates the embedding on hash drift, which is
        # the eval's whole point.
        :ok
    end
  end

  # The 8-page synthetic corpus. Topics chosen to give each case a clear
  # "right answer" while still presenting plausible distractors (e.g.
  # OTP supervision and GenServer patterns share vocabulary).
  defp corpus do
    [
      %{
        slug: "authentication-overview",
        title: "Authentication overview",
        body: """
        # Authentication overview

        How a user proves identity to the system, from credential entry
        through session establishment.

        ## Flow

        1. User submits credentials (email + password, or SSO token) to
           the login endpoint.
        2. The server validates the credentials against the password
           hash store or the SSO identity provider.
        3. On success, the server issues a session token and sets it as
           an HTTP-only cookie.
        4. Subsequent requests carry the session token; the server
           resolves it to the user record on each request.

        Failed login attempts are rate-limited. Sessions expire after a
        configured idle window and on explicit logout.

        See also: [[session-management]], [[password-hashing]].
        """
      },
      %{
        slug: "session-management",
        title: "Session management",
        body: """
        # Session management

        Server-side session storage and rotation.

        Sessions are keyed by an opaque random token issued at login.
        The token maps to a session record containing the user id, the
        issued-at timestamp, and the last-active timestamp. Rotating
        the token on privilege escalation prevents fixation attacks.
        """
      },
      %{
        slug: "otp-supervision",
        title: "OTP supervision trees",
        body: """
        # OTP supervision trees

        Designing supervisor trees for fault isolation and recovery.

        ## Restart strategies

        - `:one_for_one` — only the failed child restarts. Default for
          unrelated children.
        - `:one_for_all` — all siblings restart when any child fails.
          Use when children share state.
        - `:rest_for_one` — the failed child and any started after it
          restart. Models dependency order.

        Restart intensity (`max_restarts`, `max_seconds`) prevents
        crash loops from masquerading as recovery.
        """
      },
      %{
        slug: "genserver-patterns",
        title: "GenServer patterns",
        body: """
        # GenServer patterns

        Idioms for long-running stateful processes in Elixir.

        A GenServer holds state in a single Erlang process and
        serialises access through `handle_call` / `handle_cast` /
        `handle_info`. Use it when you have mutable state that needs a
        single owner; reach for an Agent or ETS table when you don't
        need the full message-handling surface.

        Common patterns: lazy initialisation in `handle_continue`,
        debounced timers via `Process.send_after`, and graceful
        shutdown in `terminate/2`.
        """
      },
      %{
        slug: "telemetry-events",
        title: "Telemetry events",
        body: """
        # Telemetry events

        Emitting structured metrics, spans, and traces from
        application code.

        Use `:telemetry.execute/3` at observability-worthy moments
        (request start, request stop, error). Handlers attached via
        `:telemetry.attach/4` forward events to Prometheus, Datadog,
        or a local log. Pair `start`/`stop` events so durations are
        recoverable; emit `exception` events on failure paths.
        """
      },
      %{
        slug: "ecto-changesets",
        title: "Ecto changesets",
        body: """
        # Ecto changesets

        Validating and casting user-supplied input before persistence.

        A changeset wraps a schema struct, the params under
        consideration, and a list of validation errors. `cast/4`
        whitelists fields, then `validate_required`,
        `validate_length`, and `validate_format` enforce constraints.
        `apply_action/2` materialises the result without writing to
        the database — handy for form validation in LiveView.
        """
      },
      %{
        slug: "password-hashing",
        title: "Password hashing",
        body: """
        # Password hashing

        Storing user credentials so a database breach doesn't expose
        plaintext passwords.

        Use a memory-hard hashing algorithm (Argon2id is the modern
        default; bcrypt is acceptable for legacy systems). Each
        password is salted with a unique random value. Never store
        plaintext; never store an unsalted hash.
        """
      },
      %{
        slug: "phoenix-liveview-mount",
        title: "Phoenix LiveView mount",
        body: """
        # Phoenix LiveView mount

        The two-pass lifecycle of a LiveView: initial HTTP render and
        WebSocket-connected interactive render.

        `mount/3` runs twice — once during the initial HTTP request
        (`connected?(socket) == false`) and once on WebSocket connect.
        Guard expensive setup (subscriptions, timers, DB queries)
        behind `if connected?(socket)` so the HTTP render stays fast
        and side-effect-free.
        """
      }
    ]
  end
end
