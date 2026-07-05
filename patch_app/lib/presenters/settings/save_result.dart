/// Result of a validate→save→refetch cycle — the shared seam every settings
/// section presenter's save method returns (#161), replacing three previously
/// hand-rolled and incompatible conventions (a bare `bool`, a `String?`
/// error, and a thrown `FormatException`).
sealed class SaveResult {
  const SaveResult();
}

final class SaveOk extends SaveResult {
  const SaveOk();
}

final class SaveError extends SaveResult {
  final String message;
  const SaveError(this.message);
}

/// Runs [validate]; if it returns a non-null message, saving is rejected
/// before [save] or [refetch] ever run. Otherwise runs [save] then [refetch]
/// and reports success. The shared validate→bridge-call→refetch shape every
/// settings section presenter converges on. [refetch] defaults to a no-op
/// for presenters whose bridge call's effect arrives via a push event
/// instead of an explicit refetch (e.g. macro edits).
Future<SaveResult> validateThenSave({
  required String? Function() validate,
  required Future<void> Function() save,
  Future<void> Function() refetch = _noRefetch,
}) async {
  final error = validate();
  if (error != null) return SaveError(error);
  await save();
  await refetch();
  return const SaveOk();
}

Future<void> _noRefetch() async {}
