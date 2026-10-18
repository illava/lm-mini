/// Private Arena history (Pro): the user's own saved comparisons at
/// `/users/{uid}/arena_runs/{id}`, full fidelity.
///
/// [BenchmarkService] keeps the public anonymized pool and delegates the
/// private history here. All calls are best-effort and fully guarded so the
/// app works offline / when Firebase isn't configured.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/arena_run.dart';

class ArenaHistoryStore {
  ArenaHistoryStore._();
  static final ArenaHistoryStore instance = ArenaHistoryStore._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  bool get _firebaseAvailable => Firebase.apps.isNotEmpty;

  Future<String?> _currentUserId() async {
    if (!_firebaseAvailable) return null;
    try {
      if (_auth.currentUser == null) {
        await _auth.signInAnonymously();
      }
      return _auth.currentUser?.uid;
    } catch (e) {
      if (kDebugMode) debugPrint('BenchmarkService auth error: $e');
      return null;
    }
  }

  /// Writes [run] to the user's private history. Returns true on success.
  Future<bool> savePrivate(ArenaRun run) async {
    if (!_firebaseAvailable) return false;
    final uid = await _currentUserId();
    if (uid == null) return false;
    try {
      await _db
          .collection('users')
          .doc(uid)
          .collection('arena_runs')
          .doc(run.id)
          .set({
        ...run.toJson(),
        'createdAtServer': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('BenchmarkService private save error: $e');
      return false;
    }
  }

  /// Loads the user's saved runs, newest first. Empty when not signed in /
  /// Firebase unavailable.
  Future<List<ArenaRun>> fetch({int limit = 50}) async {
    if (!_firebaseAvailable) return [];
    final uid = await _currentUserId();
    if (uid == null) return [];
    try {
      final snap = await _db
          .collection('users')
          .doc(uid)
          .collection('arena_runs')
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snap.docs
          .map((d) => ArenaRun.fromJson(d.data()))
          .toList(growable: false);
    } catch (e) {
      if (kDebugMode) debugPrint('BenchmarkService history error: $e');
      return [];
    }
  }

  Future<void> delete(String runId) async {
    if (!_firebaseAvailable) return;
    final uid = await _currentUserId();
    if (uid == null) return;
    try {
      await _db
          .collection('users')
          .doc(uid)
          .collection('arena_runs')
          .doc(runId)
          .delete();
    } catch (e) {
      if (kDebugMode) debugPrint('BenchmarkService delete error: $e');
    }
  }
}
