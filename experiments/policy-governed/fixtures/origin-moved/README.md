# D. same content, new origin  (C3)

Byte-identical content: same `expectedHash`, same `storePath`, same
`hashMode`. The ORIGIN moves to a host the trusted policy does not name.

Required trace:

    DEPENDENCY_CONTENT_UNCHANGED
    POLICY_FACTS_CHANGED
    ORIGIN_MOVED
    rejectedBy == [QUARANTINED_DEPENDENCY]

Policy evaluation RE-RAN, observably: the dependency lost
`r-github-required`, fell through to the quarantine rule, and
`effectiveDecisionDigest` moved while `dependencyContentDigest` did not.

This is what makes C3 concrete. A tool that keyed its verdict on the
content hash would see nothing here at all -- and would be right that the
bytes are the same, and wrong about everything that matters.

CONTROL: base against base is ACCEPTED.
