import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class UserService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  UserService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Creates or updates the user's root profile document at users/{user.uid}.
  /// Uses SetOptions(merge: true) so existing fields and subcollections are preserved.
  Future<void> ensureUserDocument(
    User user, {
    bool isNewUser = false,
  }) async {
    final docRef = _firestore.collection('users').doc(user.uid);
    final payload = <String, dynamic>{
      'uid': user.uid,
      'email': user.email ?? '',
      'lastLogin': FieldValue.serverTimestamp(),
    };

    if (isNewUser) {
      payload['createdAt'] = FieldValue.serverTimestamp();
      await docRef.set(payload, SetOptions(merge: true));
      return;
    }

    final snapshot = await docRef.get();
    if (!snapshot.exists) {
      payload['createdAt'] = FieldValue.serverTimestamp();
    }
    await docRef.set(payload, SetOptions(merge: true));
  }

  /// Ensures users/{uid} exists for an already-signed-in session (e.g. cold start
  /// or if LoginScreen unmounted during authStateChanges).
  Future<void> ensureUserDocumentIfMissing(String uid) async {
    try {
      final user = _auth.currentUser;
      if (user == null || user.uid != uid) return;

      final docRef = _firestore.collection('users').doc(uid);
      final snapshot = await docRef.get();
      if (!snapshot.exists) {
        await docRef.set({
          'uid': user.uid,
          'email': user.email ?? '',
          'createdAt': FieldValue.serverTimestamp(),
          'lastLogin': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Failed to ensure user document for $uid: $e');
    }
  }
}
