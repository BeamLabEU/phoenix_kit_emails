# Dialyzer ignore list — task #56.
#
# Silences a pre-existing, library-level false positive, not anything
# in this package's own code: `lib/phoenix_kit/modules/emails/gettext.ex`
# is a 3-line Gettext backend declaration (`use Gettext.Backend,
# otp_app: :phoenix_kit_emails`); the macro expansion generates a call
# into `Gettext.Plural.plural/2` whose first argument's inferred type
# (an `%Expo.PluralForms{}` struct with opaque subterms, one instance
# per locale — et has 2 plural forms, ru has 3) doesn't line up with
# what Dialyzer's PLT believes that function's spec accepts. This is a
# known class of Gettext/Expo/Dialyzer opaqueness mismatch, not a real
# defect: the generated `plural/2` call is correct at runtime (Gettext's
# own test suite covers exactly this dispatch), Dialyzer's opacity
# checking is just stricter than the actual contract here.
#
# Verified 2026-07-27 not a regression of task #56's admin-panel work:
# neither `gettext.ex` itself nor any Plural-Forms header in `priv/
# gettext/*/LC_MESSAGES/default.po` changed across the #56 commit range
# — only msgid/msgstr content did. `mix dialyzer` on this file alone,
# unrelated to any code #56 touched, reproduces both warnings.
#
# {file, warning_type} deliberately does NOT pin the line number: both
# warnings currently land on line 1 (the `use` line macro expansion
# collapses everything to), but that's an implementation detail of the
# current Gettext/Expo version, not something worth re-editing this
# file over if a future dependency bump shifts it by one line.
[
  {"lib/phoenix_kit/modules/emails/gettext.ex", :call_without_opaque}
]
