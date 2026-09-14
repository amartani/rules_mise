# backends test

This e2e exercises tools from every supported mise backend (`aqua:`,
`core:`, `forgejo:`, `github:`, `gitlab:`, `http:`, `packslip:`) from an
end-user's perspective.

It lives outside `e2e/smoke` (which is the Bazel Central Registry
presubmit module and must stay minimal) because some backends do not
provide binaries for every platform, so this suite only runs on Linux in
CI.
