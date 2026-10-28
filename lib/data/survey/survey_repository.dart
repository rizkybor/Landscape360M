import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/survey/survey_model.dart';

// Surveys in the cloud (table surveys, RLS: only the owner). Same queries as
// src/store/useSurveyStore.ts (web).

class SavedSurvey {
  const SavedSurvey({required this.id, required this.name, required this.updatedAt});

  factory SavedSurvey.fromRow(Map<String, dynamic> r) =>
      SavedSurvey(id: '${r['id']}', name: '${r['name'] ?? 'Untitled Survey'}', updatedAt: '${r['updated_at'] ?? ''}');

  final String id;
  final String name;
  final String updatedAt; // ISO

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'updated_at': updatedAt};
}

class SurveyException implements Exception {
  const SurveyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The cloud calls the Navigator needs; tests use a fake
abstract interface class SurveyBackend {
  Future<List<SavedSurvey>> list(String userId);
  Future<(String name, List<SurveyGroup> groups)> load(String id);
  Future<SavedSurvey> save({
    required String userId,
    String? id,
    required String name,
    required List<SurveyGroup> groups,
  });
  Future<void> delete(String id, String userId);
}

class SupabaseSurveyBackend implements SurveyBackend {
  SupabaseSurveyBackend(this.client);

  final SupabaseClient client;

  @override
  Future<List<SavedSurvey>> list(String userId) async {
    final rows = await client
        .from('surveys')
        .select('id, name, updated_at')
        .eq('user_id', userId)
        .order('updated_at', ascending: false);
    return rows.map(SavedSurvey.fromRow).toList();
  }

  @override
  Future<(String, List<SurveyGroup>)> load(String id) async {
    final row = await client.from('surveys').select().eq('id', id).single();
    return ('${row['name'] ?? 'Untitled Survey'}', surveyFromJson(row['data']));
  }

  @override
  Future<SavedSurvey> save({
    required String userId,
    String? id,
    required String name,
    required List<SurveyGroup> groups,
  }) async {
    final row = {
      'user_id': userId,
      'data': surveyToJson(groups),
      'name': name,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final saved = id == null
          ? await client.from('surveys').insert(row).select()
          : await client.from('surveys').update(row).eq('id', id).select();
      if (saved.isEmpty) throw const SurveyException('The survey was not saved.');
      return SavedSurvey.fromRow(saved.first);
    } on PostgrestException catch (e) {
      // surveys_storage_quota raises with HINT 'storage_quota' (20261024000004)
      if (e.hint == 'storage_quota' || e.message.toLowerCase().contains('storage')) {
        throw const SurveyException('Your cloud storage is full. Delete something or ask for more space.');
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String id, String userId) => client.from('surveys').delete().eq('id', id).eq('user_id', userId);
}
