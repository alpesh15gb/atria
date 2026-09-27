/// Single global movement-id generator.
///
/// There is exactly one `stock_movements` primary-key namespace, so the id
/// generator must also be exactly one. Two module-level counters (one per
/// repository file) each started at 1 and produced `mov_<ms>_<n>`; the first
/// movements posted by both libraries in the same millisecond collided on
/// the PK and rolled back the whole transaction.
int _movementSeq = 0;

String newStockMovementId() {
  _movementSeq = (_movementSeq + 1) & 0x3FFFFFFF;
  return 'mov_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '_${_movementSeq.toRadixString(36)}';
}
