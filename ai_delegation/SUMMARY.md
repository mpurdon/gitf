# Intelligent AI Delegation — Research Summary

**Paper**: "Intelligent AI Delegation" by Nenad Tomasev, Matija Franklin, and Simon Osindero (Google DeepMind)
**Published**: February 12, 2026 (arXiv:2602.11865v1 [cs.AI])
**Keywords**: AI, agents, LLM, delegation, multi-agent, safety

---

## 1. Introduction & Problem Statement

As AI agents tackle increasingly complex tasks, they need to meaningfully **decompose problems** and **safely delegate** sub-tasks to other AI agents and humans. Current task decomposition and delegation methods rely on **simple heuristics** and cannot dynamically adapt to environmental changes or handle unexpected failures.

The paper proposes an adaptive framework for **intelligent AI delegation**, defined as:

> "A sequence of decisions involving task allocation, that also incorporates transfer of authority, responsibility, accountability, clear specifications regarding roles and boundaries, clarity of intent, and mechanisms for establishing trust between the two (or more) parties."

Delegation is explicitly distinguished from mere task decomposition — it necessitates assignment of **responsibility**, **authority**, and **accountability**, moderated by **trust** and **risk assessment**.

The framework covers both human and AI delegators/delegatees in complex delegation networks, with the goal of informing protocols for the emerging **agentic web**.

---

## 2. Definition and Aspects of Delegation

### 2.1 Seven Axes of Delegation

1. **Delegator** — Human or AI
2. **Delegatee** — Human or AI
3. **Task Characteristics** (11 sub-dimensions):
   - **(a) Complexity** — difficulty, number of sub-steps, reasoning sophistication
   - **(b) Criticality** — importance, severity of failure consequences
   - **(c) Uncertainty** — ambiguity in environment, inputs, success probability
   - **(d) Duration** — time-frame from instantaneous to weeks
   - **(e) Cost** — economic/computational expense (tokens, API fees, energy)
   - **(f) Resource Requirements** — computational assets, tools, data access, human capabilities
   - **(g) Constraints** — operational, ethical, legal boundaries
   - **(h) Verifiability** — difficulty/cost of validating outcomes. High verifiability enables "trustless" delegation; low verifiability requires high-trust delegatees
   - **(i) Reversibility** — degree to which task effects can be undone. Irreversible tasks (financial trades, database deletion, sending emails) require stricter **liability firebreaks** and steeper **authority gradients**. Reversible tasks (drafting emails, flagging entries) need less strict controls
   - **(j) Contextuality** — volume/sensitivity of external state required. High-context tasks introduce larger **privacy surface areas**; context-free tasks can be compartmentalized to lower-trust nodes
   - **(k) Subjectivity** — preference-based vs. objective success criteria. Subjective tasks require **"Human-as-Value-Specifier"** intervention and iterative feedback loops; objective tasks can use stricter binary contracts
4. **Granularity** — fine-grained vs. coarse-grained objectives
5. **Autonomy** — full autonomy vs. prescriptive delegation
6. **Monitoring** — continuous, periodic, or event-triggered
7. **Reciprocity** — usually one-way, but can be mutual in collaborative networks

### 2.2 Delegation Scenarios

Three primary scenarios: (1) human-to-AI, (2) AI-to-AI, (3) AI-to-human. AI-to-AI interactions will grow dramatically with virtual agentic markets/economies. Delegation can be **hierarchical** (orchestrator to sub-agent) or **non-hierarchical** (peer agents).

AI-to-human delegation is flagged as concerning: algorithmic management systems in ride-hailing/logistics already delegate managerial functions to human workers, often degrading job quality, causing stress and health risks.

---

## 3. Delegation in Human Organizations

### 3.1 The Principal-Agent Problem

When a principal delegates to an agent with misaligned motivations. For AI, this manifests as:
- **Reward misspecification** — imperfect/incomplete objectives
- **Reward hacking / specification gaming** — exploiting loopholes in reward signals
- **Deceptive alignment** — frontier models can strategically underperform on safety evaluations while maintaining different behavior elsewhere

### 3.2 Span of Control

From human organizations — the limits of how many workers a single manager can effectively manage. Applied to AI:
- How many orchestrator nodes vs. worker nodes are needed
- How many AI agents a human expert can reliably oversee without fatigue
- Goal-dependent and domain-dependent
- Optimal span depends on cost vs. performance/reliability tradeoffs
- More critical tasks require higher-accuracy oversight at higher cost

### 3.3 Authority Gradient

Coined in aviation — when significant capability/authority disparities impede communication and cause errors. A more capable delegator may mistakenly presume capabilities of a delegatee. Delegatee agents may, due to **sycophancy** and instruction-following bias, be reluctant to challenge, modify, or reject requests.

### 3.4 Zone of Indifference

A range of instructions executed without critical deliberation. In current AI, defined by post-training safety filters and system instructions. Creates **systemic risk** in the agentic web: as delegation chains lengthen (A → B → C), each agent acts as an "unthinking router." The solution is engineering **"dynamic cognitive friction"** — agents must recognize when technically "safe" requests are contextually ambiguous enough to warrant stepping outside their zone of indifference.

### 3.5 Trust Calibration

Aligning trust level with a delegatee's true capabilities:
- Human operators internalizing accurate models of AI system performance
- AI delegators maintaining good models of human/AI capabilities
- Self-awareness of one's own capabilities (deciding to do it yourself)
- Explainability's role in establishing trust (fragile — quickly retracted after unanticipated errors)
- AI models' tendency toward **overconfidence** even when factually incorrect

### 3.6 Transaction Cost Economies

Contrasting internal delegation vs. external contracting costs. AI agents face four options:
1. Complete individually
2. Delegate to known sub-agent
3. Delegate to trusted agent
4. Delegate to unknown agent

Each with different expected costs and confidence levels.

### 3.7 Contingency Theory

No universally optimal organizational structure exists; the best approach depends on specific constraints. Oversight, delegatee capability, and human involvement must be **dynamically matched** to task characteristics. Stable environments allow rigid hierarchical protocols; high-uncertainty scenarios require adaptive coordination with ad-hoc escalation. Key insight: "Automation is therefore not only about what AI can do, but what AI should do."

---

## 4. Previous Work

### 4.1 Expert Systems and Mixture of Experts

- Early expert systems encoding specialized capability into software
- **Mixture of Experts (MoE)** — expert sub-systems with routing modules; features in modern deep learning (Shazeer et al., 2017; Jiang et al., 2024)

### 4.2 Hierarchical Reinforcement Learning

Delegation within a single agent using hierarchies of policies across abstraction levels. Uses **semi-Markov decision processes** with **options** and a **meta-controller**. Lacks explicit mechanisms for handling sub-policy failures or dynamic coordination.

**FeUdal Networks** — "Manager" and "Worker" architecture where the Manager operates at lower temporal resolution, setting abstract goals. The Manager **learns how to delegate** without needing mastery of lower-level actions. Potential template for learning-based delegation in agentic economies.

### 4.3 Multi-Agent Systems

- **ContractNet Protocol** — auction-based decentralized protocol where agents announce tasks and others bid
- **Coalition formation methods** — flexible configurations where agents accept/refuse membership based on utility
- **Multi-agent reinforcement learning (MARL)** — agents learn individual policies within a collective

These systems lack mechanisms for **accountability**, **responsibility**, and **monitoring**.

### 4.4 LLM-Based Agents

LLM agents integrate memory, planning, reasoning, reflection, and tool use. Task decomposition occurs either internally (coordinated sub-components) or across distinct agents.

Agent communication protocols: MCP (Anthropic, 2024), A2A (Google, 2025b), A2P (Google, 2025a), Chain-of-Agents (Li et al., 2025b).

Human-in-the-loop approaches: Different degrees of autonomy — AI as tool, interactive assistant, collaborator, or autonomous system with limited oversight. Human expertise creates a **scalability bottleneck** due to cognitive load of verifying long reasoning traces.

---

## 5. The Intelligent Delegation Framework

### 5.0 Five Core Requirements

| Pillar | Core Requirement | Technical Implementation |
|--------|-----------------|------------------------|
| **Dynamic Assessment** | Granular inference of agent state | Task Decomposition (4.1), Task Assignment (4.2) |
| **Adaptive Execution** | Handling context shifts | Adaptive Coordination (4.4) |
| **Structural Transparency** | Auditability of process and outcome | Monitoring (4.5), Verifiable Completion (4.8) |
| **Scalable Market Coordination** | Efficient, trusted coordination | Trust & Reputation (4.6), Multi-objective Optimization (4.3) |
| **Systemic Resilience** | Preventing systemic failures | Security (4.9), Permission Handling (4.7) |

Key concepts:
- **Dynamic Assessment**: Beyond reputation scores — real-time resource availability, computational throughput, budgetary constraints, context window saturation, current load, projected duration
- **Adaptive Execution**: Delegators retain capability to switch delegatees mid-execution
- **Structural Transparency**: Opacity obscures incompetence vs. malice; enforced auditability required
- **Scalable Market Coordination**: Web-scale protocols for virtual economies
- **Systemic Resilience**: Defining strict roles, bounded operational scopes. Warns of **cognitive monoculture** — insufficient diversity in delegation targets increases correlated failures

### 5.1 Task Decomposition

Optimize execution graphs for efficiency and modularity. Uses **"contract-first decomposition"** — delegation contingent on outcome having precise verification. If output is too subjective/costly/complex to verify, the system recursively decomposes further until work units match specific verification capabilities (formal proofs, automated unit tests).

Must account for **hybrid human-AI markets**, marking specific nodes for human allocation. Iteratively generate multiple decomposition proposals, match each to available delegatees, obtain estimates for success rate, cost, and duration. Keep alternative proposals **in-context** for adaptive re-adjustments.

Final specification must define roles, resource boundaries, progress reporting frequency, and required certifications.

### 5.2 Task Assignment

Matching sub-tasks to delegatees:
- **Decentralized market hubs** (not centralized registries) where delegators advertise tasks and agents submit competitive bids
- LLM agents enable **interactive negotiation** in natural language before commitment
- **Smart contracts** formalize matching: pair performance requirements with formal verification mechanisms and automated penalties for breaches
- Contracts must be **bidirectional** — protecting delegatee as rigorously as delegator (compensation for cancellation, renegotiation clauses)
- Monitoring terms negotiated pre-execution (cadence, progress reports, direct inspection)
- Privacy guardrails: anonymized/pseudonymized attestations of progress; explicit consent mechanisms for human delegators
- Two modes of execution: **atomic execution** (strict specs for narrow tasks) and **open-ended delegation** (authority to decompose and pursue sub-goals)
- **Recursive delegation**: delegating the act of delegation itself

### 5.3 Multi-Objective Optimization

A delegator rarely optimizes a single metric. Competing objectives:

- **Cost vs. quality** — high-performing agents command higher fees
- **Latency vs. cost** — reducing resource consumption means slower execution
- **Uncertainty vs. expenditure** — reputable agents reduce risk but increase cost
- **Privacy vs. performance** — full context transparency maximizes performance; privacy-preserving techniques incur computational overhead

The delegator navigates a **"trust-efficiency frontier"** seeking to maximize success probability while satisfying constraints on context leakage and verification budgets.

Seeks **Pareto optimality** — selected solution not dominated by any other attainable option. Optimization is a **continuous loop** integrating monitoring signals, updating beliefs about agent likelihood of success, expected duration, and cost. Significant drift triggers **re-optimization and re-allocation**, incorporating the **cost of adaptation** (overhead/waste from mid-execution switching).

**Complexity floor**: Below a certain complexity threshold, tasks should bypass intelligent delegation in favor of direct execution, because transaction costs would exceed task value.

### 5.4 Adaptive Coordination

For high-uncertainty or long-duration tasks, static plans are insufficient.

**External triggers** for re-delegation:
1. Delegator alters task specification
2. Task cancellation
3. Resource availability/cost changes (API outages, dataset access loss, compute spikes)
4. Higher-priority task preemption
5. Security system detection of malicious/harmful actions

**Internal triggers**:
1. Performance degradation below service level objectives
2. Budget overrun or need for resource increase
3. Intermediate artifact failing verification check
4. Delegatee becoming unresponsive

**Adaptive Response Cycle**: Continuous monitoring → issue detection → root cause diagnosis → response scenario evaluation → response urgency assessment → execution (parameter adjustment, sub-task re-delegation, or full task re-decomposition). Irreversible high-criticality failures trigger **immediate termination or human escalation**.

**Centralized vs. Decentralized orchestration**:
- Centralized: single orchestrator with global view, but introduces **single point of failure** and is limited by **computational span of control**
- Decentralized: market-based auction queues; defaulting agents cover price differences as penalty; multi-round negotiation for complex tasks; **smart contracts** with pre-agreed executable clauses

**Market stability measures** to prevent over-triggering:
- Cooldown periods for re-bidding
- Damping factors in reputation updates
- Increasing fees on frequent re-delegation

### 5.5 Monitoring

Systematic process of observing, measuring, and verifying delegated task state/progress/outcomes.

#### Monitoring Taxonomy (5 Dimensions)

| Dimension | Option A (Lightweight) | Option B (Intensive) |
|-----------|----------------------|---------------------|
| **Target** | Outcome-Level — post-hoc validation of final results using binary success flags or quality scores | Process-Level — continuous tracking of intermediate states, resource consumption, and methodology |
| **Observability** | Indirect — inferring progress via environmental side-effects (file system changes) | Direct — explicit status polling, push notifications, or real-time event streaming APIs |
| **Transparency** | Black-Box — input/output observation only; internal state hidden | White-Box — full inspection of internal reasoning traces, decision logic, and memory |
| **Privacy** | Full Transparency — delegatee reveals all data and intermediate artifacts | Cryptographic — zk-SNARKs or Secure Multi-Party Computation to verify correctness without revealing data |
| **Topology** | Direct — monitoring only the immediate delegatee (1-to-1) | Transitive — relying on signed attestations from intermediate agents to verify sub-delegatees |

**Standardized observability events**: `TASK_STARTED`, `CHECKPOINT_REACHED`, `RESOURCE_WARNING`, `TASK_COMPLETED`.

Technical implementations include polling REST endpoints, webhook push notifications, and event streaming (Apache Kafka, gRPC streams).

#### Cryptographic Verification

- **zk-SNARKs** — succinct non-interactive arguments of knowledge that prove a computation was performed correctly without revealing the data
- **Homomorphic encryption** — allows computation on encrypted data
- **Secure multi-party computation**

#### Transitive Monitoring

In delegation chains (A → B → C), Agent A may not be able to directly monitor Agent C. The paper proposes **transitive accountability via attestation**: Agent B monitors C, generates a summary report, cryptographically signs it, and forwards it to A. This requires A to trust B's verification capabilities, which can be ensured through **third-party certification**.

### 5.6 Trust and Reputation

**Trust**: The delegator's degree of belief in a delegatee's capability to execute a task in alignment with explicit constraints and implicit intent. Dynamically formed and updated based on verifiable data streams from monitoring.

**Reputation**: A public, verifiable history of an agent's reliability, acting as a predictive signal and proxy for latent reliability and alignment.

Trust is **private and context-dependent**; reputation is **public and verifiable**. Higher trust enables lower monitoring and verification costs.

#### Three Reputation Implementation Models

| Model | Mechanism | Strengths | Weaknesses |
|-------|-----------|-----------|------------|
| **Immutable Ledger** | Blockchain recording task outcomes, resource consumption, constraint adherence as verifiable transactions | Foundational performance history | Susceptible to gaming (agents inflating reputation by only accepting simple tasks) |
| **Web of Trust** | Decentralized Identifiers (DIDs) issuing signed, context-specific Verifiable Credentials attesting to capabilities | Domain-specific expertise portfolio | Complex infrastructure |
| **Behavioral Metrics** | Transparency scores and safety scores derived from analyzing execution process | Evaluates *how* tasks are performed, not just results | Requires white-box monitoring |

#### Reputation in the Delegation Lifecycle

- During **initial matching**: as a delegatee filtering mechanism
- For **dynamic scoping of authority**: **graduated authority** means low-trust agents face strict constraints (transaction caps, mandatory oversight), while high-reputation agents operate with minimal intervention
- Reputation becomes a **valuable intangible asset**, creating economic incentives for reliable behavior

#### Trust and Human Participants

When a trustworthy agent faithfully executes **malicious human instructions**, it risks unfair reputational damage. Agents must rigorously evaluate incoming requests, solicit clarification, or reject inappropriate requests. Market audits must distinguish between **agent execution failure** and **malicious directives** for accurate **liability attribution**.

### 5.7 Permission Handling

**Risk-adaptive permission model**:
- **Low-stakes tasks** (low criticality, high reversibility): Agents get **default standing permissions** derived from verifiable attributes (organizational membership, safety certifications, reputation scores above a threshold)
- **High-stakes tasks** (high criticality, high contextuality): Permissions are granted **just-in-time**, strictly scoped to the task's duration, and gated by **mandatory human-in-the-loop approval** or third-party authorization
- **Confused deputy problem**: A compromised agent with valid credentials being tricked into misusing them

Key mechanisms:
- **Privilege attenuation**: When sub-delegating, an agent cannot transmit its full set of authorities; it must issue permissions restricted to the strict subset of resources needed
- **Semantic constraints**: Access defined not just by tool/dataset but by allowable operations (e.g., read-only access to specific rows, execute-only for a specific function)
- **Meta-permissions**: Governing which permissions a delegator in the chain is allowed to grant downstream
- **Continuous validation and automated revocation**: Permissions are dynamic states, not static endowments. **Algorithmic circuit breakers** automatically invalidate tokens if reputation drops or anomalies are detected
- **Policy-as-code**: Permissioning rules defined as auditable, versionable, mathematically verifiable code

### 5.8 Verifiable Task Completion

The contractual cornerstone of the framework. The **contract-first decomposition principle** demands that task granularity be tailored a priori to match available verification capabilities.

#### Four Verification Mechanisms

1. **Direct outcome inspection** — for auto-verifiable domains like code generation (run tests, compile, type-check)
2. **Trusted third-party auditing** — specialized auditing agents, certified human experts, or adjudication panels
3. **Cryptographic proofs** — zk-SNARKs for trustless, automated verification
4. **Game-theoretic consensus** — verification games inspired by TrueBit, using Schelling points and economic incentives

Upon successful verification, the delegator issues a **cryptographically signed verifiable credential** — a non-repudiable receipt stating "Agent A certifies that Agent B successfully completed Task T on Date D to Specification S." This credential feeds into B's permanent, verifiable reputation log.

**Smart contracts** hold payment in **escrow** with verification clauses specifying fund release conditions.

#### Verification in Delegation Chains

In chains (A → B → C):
- A has no direct contractual relationship with C
- B is responsible for verifying C's sub-task and obtaining proof
- When B submits to A, it includes the full **chain of attestations**
- A's verification process: (1) verify B's direct work, (2) verify that B correctly verified C's work
- **Responsibility is transitive** — agents cannot absolve themselves by blaming subcontractors
- **Liability follows the chain of contracts**: if A suffers loss from C's failure, A holds B liable; B then seeks recourse from C

#### Dispute Resolution

For markets with high subjectivity and low intrinsic verifiability:
- **Arbitration clause** and **escrow bond** are mandatory
- The delegatee posts a **financial stake** prior to execution
- **Optimistic model**: task assumed successful unless formally challenged within a **predefined dispute period**
- Unresolved disputes go to **decentralized adjudication panels** (human experts or AI agents)
- **Retroactive reputation updates** occur even outside the dispute window for post-hoc error discovery

### 5.9 Security

#### Malicious Delegatee Threats

- **Data Exfiltration**: Stealing sensitive/proprietary data
- **Data Poisoning**: Returning subtly corrupted data
- **Verification Subversion**: Using prompt injection to jailbreak AI critics
- **Resource Exhaustion**: Denial-of-service via excessive resource consumption
- **Unauthorized Access**: Using malware to obtain elevated privileges
- **Backdoor Implanting**: Embedding concealed triggers in generated artifacts

#### Malicious Delegator Threats

- **Harmful Task Delegation**: Delegating illegal/unethical tasks
- **Vulnerability Probing**: Benign-seeming tasks designed to probe security controls
- **Prompt Injection and Jailbreaking**: Crafting task instructions to bypass safety filters
- **Model Extraction**: Queries designed to distill the delegatee's proprietary system prompt
- **Reputation Sabotage**: Submitting valid tasks but reporting false failures to damage competitors

#### Ecosystem-Level Threats

- **Sybil Attacks**: One adversary creates many fake identities to manipulate reputation systems
- **Collusion**: Agents colluding to fix prices or blacklist competitors
- **Agent Traps**: Adversarial instructions embedded in environmental content to hijack agent control flow
- **Agentic Viruses**: Self-propagating prompts that execute malicious actions and re-generate themselves
- **Protocol Exploitation**: Exploiting smart contract vulnerabilities (reentrancy attacks, front-running auctions)
- **Cognitive Monoculture**: Over-dependence on a limited number of foundation models creating single points of failure

#### Defense-in-Depth Strategy (Four Layers)

1. **Infrastructure level**: Execute sensitive tasks within **Trusted Execution Environments (TEEs)**; use remote attestation to verify unmodified agent code
2. **Access control**: **Principle of least privilege** through strict sandboxing
3. **Application interface**: Robust **security frontend** to sanitize task specifications against prompt injection
4. **Network and identity layer**: **Decentralized Identifiers (DIDs)** for all participants, cryptographic signing of all messages, **mutually authenticated TLS** for all network traffic

---

## 6. Ethical Delegation

### 6.1 Meaningful Human Control

- Risk of **erosion of meaningful human control** through automation
- **Zone of indifference**: Humans naturally develop a tendency to accept AI decisions without scrutiny
- **Moral crumple zone**: Where human experts lack meaningful control over outcomes but are introduced in delegation chains merely to absorb liability
- Solution: **Cognitive friction** — active measures that introduce deliberate friction during oversight to ensure flagged decisions are evaluated carefully
- Challenge of **alarm fatigue**: if verification requests are sent too frequently, overseers default to heuristic approval
- Must be **context-aware**: seamless execution for low-criticality tasks, with dynamically increased cognitive load for high-uncertainty scenarios

### 6.2 Accountability in Long Delegation Chains

The **accountability vacuum** emerges as distance grows between original intent (X) and ultimate execution (Y) in chains like X → A → B → C → ... → Y.

**Liability firebreaks** — predefined contractual stop-gaps where an agent must either:
1. Assume **full, non-transitive liability** for all downstream actions
2. **Halt execution** and request an updated transfer of authority from the human principal

The system must maintain **immutable provenance** — an auditorially transparent chain of custody.

### 6.3 Reliability and Efficiency

**Reliability premium** — the additional latency and computational cost of verification mechanisms. Recommendations:
- **Tiered service levels**: low-cost delegation for routine tasks, high-assurance for critical functions
- Ethical risk that **safety becomes a luxury good** if high-assurance delegation is expensive
- **Minimum viable reliability** as a baseline guaranteed for all users
- **Safety floors**: mandatory verification steps for specific task classes that cannot be bypassed for efficiency

### 6.4 Social Intelligence

AI agents functioning as **teammates** and occasionally as **managers**:
- Avoiding scenarios where humans feel **micromanaged by algorithms**
- AI agents must form **mental models** of human delegatees and understand team relationships
- Managing the **authority gradient**: assertive enough to challenge human errors (overcoming sycophancy) while remaining open to valid overrides
- Risk that AI agents may **fragment team networks**; mitigation includes delegating tasks to groups or via human intermediaries
- **Bi-directional clarity**: agents explain their own actions and proactively seek clarification on ambiguous directives

### 6.5 User Training

Equipping human participants to function as delegators, delegatees, or overseers:
- AI literacy through carefully crafted user interfaces and education/co-training
- Policy frameworks defining **delegation boundaries** based on task sensitivity and domain context
- Clarity on **certification levels** required for delegatees
- Granting AI agents **just the right level of autonomy** for each specific task

### 6.6 Risk of De-skilling

The **paradox of automation** (Bainbridge, 1983): As AI handles routine workflows, humans are removed from the loop, intervening only for complex edge cases. Without situational awareness from routine work, humans become **ill-equipped to handle critical failures**. This creates a **fragile setup** where humans retain accountability but lose hands-on experience.

Mitigations:
- **Intentionally delegating some tasks to humans** that AI could handle, to maintain skills
- Requiring human experts to accompany judgments with **detailed rationales** or **pre-mortems**
- Protecting the **organizational apprenticeship pipeline**: routine tasks most likely to be AI-automated are precisely those that build junior expertise
- **Curriculum-aware task routing systems**: track skill progression of junior team members, strategically allocate tasks within their **zone of proximal development**, with AI agents co-executing and progressively withdrawing support

---

## 7. Protocols

### 7.1 MCP (Model Context Protocol)

Anthropic, 2024; Microsoft, 2025:
- Standardizes how AI models connect to external data/tools via a **client-host-server architecture**
- Uses **JSON-RPC messages** over stdio or HTTP SSE
- Reduces transaction cost of delegation via uniform interface
- Enables **black-box monitoring** through uniform logging
- **Gaps**: Lacks a policy layer for usage permissions; provides binary access without **semantic attenuation** (e.g., restricting to read-only scopes); stateless regarding internal reasoning; agnostic to liability with no native mechanisms for reputation or trust

### 7.2 A2A (Agent-to-Agent)

Google, 2025b:
- Peer-to-peer transport layer for the agentic web
- Defines **agent cards** (JSON-LD manifests listing capabilities, pricing, verifiers) for capability matching
- Supports asynchronous event streams via **WebHooks and gRPC** (e.g., `TASK_BLOCKED`, `RESOURCE_WARNING`)
- **Gaps**: Designed for coordination, not adversarial safety; no cryptographic slots for verifiable task completion; no native support for structured pre-commitment negotiation of scope, cost, and liability

### 7.3 AP2 (Agent Payment Protocol)

Parikh and Surapaneni, 2025:
- Standard for **mandates** — cryptographically signed intents authorizing agents to spend funds on behalf of a principal
- Valuable for implementing **liability firebreaks** by creating ceilings on potential financial loss
- **Stake-on-bid mechanisms** mitigate Sybil attacks by requiring delegatees to lock funds alongside bids
- Provides **non-repudiable audit trails** for provenance of intent
- **Gaps**: No task execution quality verification; no conditional settlement logic; no protocol-level clawback mechanism

### 7.4 UCP (Universal Commerce Protocol)

Handa and Google Developers, 2026:
- Standardizes dialogue between consumer-facing agents and backend services
- Facilitates Task Assignment through dynamic capability discovery
- Treats payment as a **first-class, verifiable subsystem** with cryptographic proofs
- Standardizes negotiation flow (discovery, selection, transaction)
- **Gaps**: Architecture optimized for commercial intent; may require extension for abstract computational tasks

### 7.5 Proposed Delegation-centered Protocol Extensions

#### A2A Task Object Extension

Adding a `verification_policy` field specifying:
- Verification mode ("strict")
- Required artifacts (unit test logs, zk-SNARK traces)
- Validator endpoints (MCP-based)
- Signature requirements
- Escrow triggers

#### MCP Monitoring Stream Extension

Logging internal control loop events via Server-Sent Events with negotiated granularity levels:
- `L0_IS_OPERATIONAL`
- `L1_HIGH_LEVEL_PLAN_UPDATES`
- `L2_COT_TRACE` (chain-of-thought trace)
- `L3_FULL_STATE`

#### Request for Quote (RFQ) Protocol

Delegator broadcasts a `Task_RFQ`; agents respond with signed `Bid_Objects` containing:
- `agent_id` (DID)
- `estimated_cost`
- `estimated_duration`
- `privacy_guarantee` (e.g., TEE enclave SGX)
- `reputation_bond`
- `expiry`

#### Delegation Capability Tokens (DCTs)

Based on **Macaroons** or **Biscuits** — attenuated authorization tokens. A delegator mints a DCT wrapping resource credentials with cryptographic caveats (e.g., "access Google Drive MCP server, BUT ONLY for folder Project_X AND ONLY for READ operations"). Tokens are invalidated if restrictions are violated. DCTs support **restriction chaining** — each participant in a delegation chain can add further restrictions but never remove existing ones.

#### Checkpoint Artifacts

Standard schema for checkpoint artifacts enabling tasks to be resumed or restarted with minimal overhead. Agents periodically commit a `state_snapshot` to shared storage referenced in the A2A Task Object, preventing total work loss. Coupled with smart contract clauses enabling **partial compensation** and verification of task completion percentage.

---

## 8. Conclusion

The paper's vision:
- Significant components of the future global economy will be mediated by millions of specialized AI agents
- Current ad-hoc, heuristic-based delegation is **insufficient** for this transformation
- Advocates a **paradigm shift from unsupervised automation to verifiable, intelligent delegation**
- Core principles: decompose to match verification capabilities, allocate based on bids/trust/reputation/cost, enforce structured permissions and tiered approvals for high-stakes tasks, maintain appropriate human oversight
- **Safety and accountability must be baked into operational principles** at the protocol level, not treated as an afterthought

---

## Key Terminology Reference

| Term | Definition |
|------|-----------|
| **Intelligent Delegation** | Task allocation + transfer of authority, responsibility, accountability, roles, boundaries, trust |
| **Principal-Agent Problem** | Misaligned motivations between delegator and delegatee |
| **Span of Control** | Limits of how many agents a single overseer can manage |
| **Authority Gradient** | Capability/authority disparities impeding communication |
| **Zone of Indifference** | Range of instructions executed without critical deliberation |
| **Dynamic Cognitive Friction** | Engineering agents to challenge contextually ambiguous requests |
| **Trust Calibration** | Aligning trust level with true capabilities |
| **Transaction Cost Economies** | Comparing internal vs. external delegation costs |
| **Contingency Theory** | No universal optimal structure; adapt to constraints |
| **Contract-First Decomposition** | Delegation contingent on output having precise verification |
| **Liability Firebreaks** | Strict controls/stop-gaps for irreversible tasks and long chains |
| **Human-as-Value-Specifier** | Human intervention required for subjective success criteria |
| **Trust-Efficiency Frontier** | Tradeoff between success probability and context leakage/verification cost |
| **Pareto Optimality** | No other attainable option dominates the selected solution |
| **Complexity Floor** | Threshold below which direct execution beats delegation overhead |
| **Cognitive Monoculture** | Insufficient diversity in delegation targets causing correlated failures |
| **Graduated Authority** | Trust-level-dependent permission scoping |
| **Privilege Attenuation** | Sub-delegatees receive only a strict subset of the delegator's permissions |
| **Algorithmic Circuit Breakers** | Auto-revoke permissions on anomaly detection |
| **Moral Crumple Zone** | Humans absorbing liability without meaningful control |
| **Minimum Viable Reliability** | Baseline safety guaranteed regardless of cost tier |
| **Paradox of Automation** | Removing humans from routine work leaves them ill-equipped for critical failures |
| **Delegation Capability Tokens** | Attenuated authorization tokens based on Macaroons/Biscuits |

---

## Intellectual Foundations (from Bibliography, Pages 29-42)

The paper synthesizes insights from six distinct research traditions:

1. **Economics** — Principal-agent theory, transaction cost economics, market mechanisms (Grossman & Hart, Williamson, Myerson, Sannikov)
2. **Organizational Theory** — Span of control, contingency theory, authority gradients, delegation of authority (Ouchi & Dowling, Donaldson, Alkov et al.)
3. **Multi-Agent Systems** — Coalition formation, contract net protocols, trust models, hierarchical RL (Smith, Sandholm, Vezhnevets, Albrecht et al.)
4. **AI Safety and Alignment** — Guardrails, reward hacking, specification gaming, sycophancy, alignment faking, sleeper agents (Amodei et al., Hubinger et al., Greenblatt et al., Sharma et al.)
5. **Human-AI Interaction** — Trust calibration, automation complacency, human-in-the-loop design, cognitive challenges (Bainbridge, Parasuraman, Green, Hemmer et al.)
6. **Security and Verification** — Prompt injection, adversarial attacks, cryptographic verification (zk-SNARKs, MPC), decentralized identity, protocol standards (Greshake et al., Cohen et al., Bitansky et al., Birgisson et al.)

---

## Mapping to Hive: Current Architecture

### Hive Entity Lifecycle

Understanding which entities are persistent vs ephemeral is critical for applying the paper's ideas:

| Entity | Process Lifetime | Data Lifetime | Identity |
|---|---|---|---|
| **Bees** | Ephemeral (spawn per job, die on completion) | Record persists in Store (`bee` prefix) | Random names, no cross-job identity |
| **Council Experts** | N/A (file-based) | **Persistent** (`.hive/councils/<name>/<key>-expert.md` + Store) | Stable key, reusable across quests |
| **Councils (aggregate)** | N/A (context module) | **Persistent** (Store with `cnl` prefix) | Stable ID, applied to multiple quests |
| **Tech Agent Profiles** | N/A (file-based) | **Persistent** (per-comb, cached `.md` files) | Keyed by tech stack detection |
| **Task Skills** | Per-bee | **Ephemeral** (dies with worktree) | None |
| **Model + job-type combos** | N/A | Implicit in cost/job data | Derivable from existing records |
| **Quests / Jobs** | N/A (context modules) | **Persistent** (Store) | Stable IDs |

**Key insight**: Bees are disposable workers — tracking reputation per-bee is meaningless since they have no persistent identity across jobs. The paper's reputation concepts should instead be applied to the **persistent entities that shape outcome quality**: council experts, councils, agent profiles, and model-task pairings.

### Existing Infrastructure That Maps to the Paper

| Paper Concept | Hive Component | Status |
|---|---|---|
| Task Decomposition | `Queen.Planner` creates jobs with acceptance criteria, dependency graphs with cycle detection | Functional |
| Task Assignment | Queen spawns bees with model tiering (`Jobs.Classifier`), concurrency cap (`max_bees`) | Functional |
| Outcome-Level Monitoring | Waggle messages (`job_complete`, `job_failed`), cost tracking per-bee | Functional |
| Verification | `Hive.Verification` — tests, static analysis, security scan, quality scoring | Functional |
| Budget Enforcement | `Hive.Budget` — per-quest budget caps, checked before spawning | Functional |
| Failure Analysis | `Hive.Intelligence` — classifies failures, finds patterns, generates suggestions | Functional |
| Adaptive Retry | `Intelligence.Retry` — model switching, scope simplification, context handoff, fresh worktrees | Functional |
| Design Iteration | Orchestrator loops review → design up to 2 times with feedback | Functional |
| Cell Isolation | Each bee gets its own git worktree | Functional |
| **Sandboxing (Bubblewrap)** | `Hive.Sandbox.Bubblewrap` — Linux namespace isolation via `bwrap`: unshares all namespaces, read-only root, RW only on worktree, `--die-with-parent`, `--new-session`. Falls back to Docker adapter or local execution. | **Functional — provides the enforcement mechanism for risk-adaptive permissions** |
| Permission Scoping | Queen gets restricted perms (no Write/Edit); bees get broad dev tool access | Partial — same permissions for all bees regardless of job risk |

## Improvement Opportunities

### Tier 1 — High Impact, Builds on Existing Infrastructure

#### 1.1 Reputation System for Persistent Entities

Track performance history on the entities that actually persist and influence outcomes:

**Council Experts** (strongest candidate):
- Track which expert personas produce better review outcomes (fewer post-merge regressions, higher validation pass rates)
- Track which experts' review waves produce the most actionable changes
- Track which experts pair well together
- Store reputation data alongside existing council records in the Store

**Councils (aggregate)**:
- Quest success rate when this council was applied vs. not applied
- Average review wave impact on quality scores
- Cost efficiency (do council reviews reduce retry counts enough to justify their cost?)

**Tech Agent Profiles**:
- Job success rate by agent type (do `react-expert` bees succeed more often than `python-expert` bees?)
- Cost efficiency by agent type
- Retry frequency by agent type

**Model + Job-Type Pairings**:
- Success rate, quality score, cost, and duration by model per job complexity class
- Use historical data to improve `Jobs.Classifier` recommendations
- Existing `Hive.Costs` and `Hive.Intelligence` data can seed this

**How to use it**: Feed reputation scores into job assignment decisions. Prefer high-performing council experts for critical reviews. Route jobs to model tiers with best historical performance for that job type. Deprioritize or retire underperforming agent profiles.

Implements the paper's **"behavioral metrics" reputation model** and **"graduated authority"** concepts.

#### 1.2 Risk-Adaptive Permissions via Bubblewrap Policy Layer

Hive already has the **enforcement mechanism** via `Hive.Sandbox.Bubblewrap` (namespace isolation, read-only root, die-with-parent). What's missing is a **policy layer** that decides *when* and *how tightly* to apply it based on job characteristics.

**Job risk classification** using the paper's task characteristic dimensions:
- **Criticality**: Does the job touch security-sensitive code, DB migrations, infrastructure config, auth systems?
- **Reversibility**: Are changes easily reverted (new files, tests) vs. hard to undo (data migrations, config changes)?
- **Contextuality**: Does the job need access to secrets, credentials, or sensitive data?

**Tiered sandbox profiles**:

| Risk Level | Sandbox Config | Claude Permissions | Example Jobs |
|---|---|---|---|
| **Low** | Bubblewrap with shared network + RW worktree (current default) | Full dev tool access | Tests, docs, new feature files |
| **Medium** | Bubblewrap with restricted bind mounts (only target directories visible) | Standard tools, no `curl`/`wget` | Refactors, bug fixes touching multiple files |
| **High** | Bubblewrap with `--unshare-net` (no network) | Restricted tools, no Write outside worktree | DB migrations, security-sensitive code, config changes |
| **Critical** | Docker adapter with full isolation | Minimal tools, human approval before merge | Infrastructure, auth systems, deployment configs |

**Implementation**: Extend `Hive.Runtime.Settings.generate_settings/1` to accept a risk level and produce per-job permission profiles. Add a `classify_risk/1` function (similar to existing `Jobs.Classifier`) that examines job description, target files, and acceptance criteria to determine the risk tier. Wire through `Hive.Sandbox` adapter selection.

Implements the paper's **risk-adaptive permission model**, **privilege attenuation**, and **semantic constraints**.

#### 1.3 Process-Level Monitoring with Checkpoints

Add a `CHECKPOINT_REACHED` waggle type. Instrument bee wrapper scripts to periodically report progress (files changed, tests passing, time elapsed). The Queen can detect stalled bees earlier than the current "is the process dead?" check.

Maps to the paper's **L0-L3 monitoring granularity**:
- `L0`: Bee process is alive (current capability via process checks)
- `L1`: High-level progress updates (files touched, phase of work)
- `L2`: Reasoning trace summaries (what the bee is attempting)
- `L3`: Full state (context window usage, tool call history)

Standardized events: `BEE_STARTED`, `CHECKPOINT_REACHED`, `RESOURCE_WARNING` (context window filling up, approaching budget), `BEE_COMPLETED`.

#### 1.4 Alternative Plan Evaluation

Have the Planner generate 2-3 candidate decompositions, score them on estimated cost/complexity/parallelism, and pick the best. Keep runners-up in the quest record for fallback if the primary plan fails repeatedly. Implements the paper's "keep alternative proposals in-context."

#### 1.5 Complexity Floor / Fast Path

For simple jobs (single-file changes, small fixes), skip the full quest pipeline and run a single bee directly. The paper's insight: delegation overhead can exceed task value. Classify at quest creation time and route accordingly.

### Tier 2 — Medium Impact, New Capabilities

#### 2.1 Adaptive Re-decomposition

When multiple jobs in a quest fail, trigger re-planning rather than just retrying individual jobs. The Orchestrator already has phase looping for design — extend this to the planning phase. Use failure analysis output to inform the re-plan.

#### 2.2 Dynamic Cognitive Friction for Bees

Add system prompt instructions for bees to flag ambiguous acceptance criteria, challenge potentially destructive operations, and request clarification via waggle before proceeding. Implement a `clarification_needed` waggle type that pauses the job and notifies the Queen/user.

#### 2.3 Graduated Authority Over Time

Use the reputation system (Tier 1.1) to dynamically adjust verification strictness. High-reputation council experts or model-task combos with strong track records get lighter verification (skip some checks, allow auto-merge). After failures, tighten controls. This is the paper's "graduated authority" applied longitudinally.

#### 2.4 Budget-Aware Multi-Objective Assignment

Optimize across cost, expected quality, and latency using historical reputation data rather than simple heuristic model selection. Navigate the paper's **"trust-efficiency frontier"** — for each job, evaluate whether the cheaper model has a good enough track record for this job type, or whether the quality risk justifies spending more on a capable model.

### Tier 3 — Aspirational / Longer-term

#### 3.1 Human-in-the-Loop Checkpoints for Critical Quests

For quests touching security, infrastructure, or user-facing systems, insert mandatory human approval gates before merge. Implement the paper's **"liability firebreaks"** where the system halts and presents a summary for human sign-off. Avoid alarm fatigue by only triggering on high-criticality quests (use the risk classification from Tier 1.2).

#### 3.2 Model Diversity (Anti-Monoculture)

Support multiple LLM backends for bees (Gemini, GPT, local models via existing `reqllm_provider` plugin). Use different models for verification than for implementation (cross-model auditing). Reduces the paper's **"cognitive monoculture"** risk — correlated failures from over-dependence on a single foundation model.

#### 3.3 Formal Verification Contracts

Extend job specs with explicit verification policies: what must pass (tests, type checks, security scans), minimum quality score thresholds, and who/what verifies. Make verification a first-class part of the job record rather than a global config. This is the paper's **"contract-first decomposition"** taken to its logical conclusion.

#### 3.4 Post-Completion Review Window

After merge, keep a review window where automated regression detection can flag problems and trigger rollback or follow-up quests. Feed results back into the reputation system. Implements the paper's **"retroactive reputation updates"** and **"dispute resolution"** concepts.
