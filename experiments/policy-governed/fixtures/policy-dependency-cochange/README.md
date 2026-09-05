# E. policy and dependency in one proposal

One proposal that BOTH weakens the policy AND adds the dependency the
weakening applies to. The dependency itself is unobjectionable: under the
base policy alone it is accepted, coverage `required`. The weakening is
narrow and plausible -- it exempts exactly one vendor.

Required trace:

    POLICY_DEPENDENCY_COCHANGE
    rejectedBy == [POLICY_DEPENDENCY_COCHANGE]   -- and nothing else

The single-entry rejectedBy is the point of this fixture. Nothing else
about this proposal is wrong, so if the cochange guard were deleted this
specimen would go green -- which is what makes it a specimen.

The first version refuses to be clever here. It does not weigh whether the
exemption is reasonable. The policy change lands on the base first; the
dependency arrives in a later proposal, governed by a policy that was
already reviewed on its own.

CONTROL: base against base is ACCEPTED.
