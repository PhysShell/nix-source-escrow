# A. policy self-exemption  (C1)

The candidate adds a dependency from a host the base policy admits only
under quarantine, and in the same proposal writes the rule that would
exempt exactly that host.

Required trace:

    POLICY_CHANGED = YES
    ENFORCED_POLICY_COMMIT = <base>
    rejectedBy includes QUARANTINED_DEPENDENCY

The exemption is REAL: the preview in the gate report shows that under the
proposed policy this dependency would have been accepted. It simply is not
the policy that decided this proposal.

CONTROL: base gated against base is ACCEPTED. Without that, this fixture
would be red whether or not the base policy governed anything.
