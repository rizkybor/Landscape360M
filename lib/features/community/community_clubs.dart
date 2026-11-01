import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/photo_compress.dart';
import '../../domain/community/community.dart';
import 'community_club_page.dart';
import 'community_compose.dart' show communityPhotoPickerProvider;
import 'community_state.dart';
import 'community_widgets.dart';

// Community Clubs (20261102000025, 20261102000026): my clubs; Enterprise accounts and the
// admin create them and add members by email. In a club the leader (its owner) edits its
// profile (photo, about, home base, contact), adds and removes members and deletes it; a
// member can leave. A club's posts are for its members only.

Future<void> openClubs(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const ClubsPage()));

class ClubsPage extends ConsumerWidget {
  const ClubsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Clubs')),
    body: RefreshIndicator(
      onRefresh: () => ref.refresh(myClubsProvider.future),
      child: ListView(
        key: const Key('clubs-list'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: const [ClubsList()],
      ),
    ),
  );
}

/// My clubs as cards (avatar, members, leader, new posts), New club for those who may, and
/// the empty state; the Clubs tab and the Clubs page
class ClubsList extends ConsumerWidget {
  const ClubsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(myClubsProvider);
    final limits = ref.watch(communityLimitsProvider).value;
    final canCreate = limits?.canCreateClubNow ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canCreate)
          OutlinedButton.icon(
            key: const Key('club-create'),
            onPressed: () => showClubForm(context),
            icon: const Icon(Icons.add, size: 18),
            label: Text(
              limits?.clubsLeft == null ? 'New club' : 'New club (${limits!.clubsLeft} left)',
              key: const Key('clubs-left'),
            ),
          )
        else if (limits != null && !limits.canCreateClubs)
          const Text(
            'Starting a club is for Enterprise accounts. You can still be added to one.',
            style: TextStyle(fontSize: 11, color: L360Colors.sand500),
          ),
        const SizedBox(height: 10),
        ...switch (clubs) {
          AsyncData(:final value) when value.isEmpty => [
            EmptyState(
              icon: Icons.groups_outlined,
              title: 'No clubs yet',
              text: limits?.canCreateClubs ?? false
                  ? 'Start a club for your Mapala, team or trip group: members-only posts and a shared workspace.'
                  : 'Ask a club leader to add you by email or send you an invite link.',
            ),
          ],
          AsyncData(:final value) => [
            for (final c in value) ...[
              CommunityCard(
                key: Key('club-${c.id}'),
                onTap: () => openClub(context, c.id),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      ClubAvatar(club: c),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                            ),
                            Text(
                              [
                                '${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
                                if (c.isOwner) 'Leader' else 'Leader: ${c.ownerName}',
                                if (c.role == ClubRole.admin) 'Admin',
                                if (c.region?.isNotEmpty ?? false) c.region!,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, color: L360Colors.sand600),
                            ),
                          ],
                        ),
                      ),
                      if (c.newPosts > 0) CountBadge(c.newPosts, key: Key('club-new-${c.id}')),
                      const Icon(Icons.chevron_right, color: L360Colors.sand400),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
          AsyncError(:final error) => [ErrorBanner('$error')],
          _ => [const LoadingCards(count: 2)],
        },
      ],
    );
  }
}

/// New club, or the leader editing [club]'s profile (photo, name, about, home base, contact)
Future<void> showClubForm(BuildContext context, {CommunityClub? club}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _ClubForm(club: club),
);

/// The club's photo, else the first letter of its name
class ClubAvatar extends ConsumerWidget {
  const ClubAvatar({super.key, required this.club, this.size = 40});

  final CommunityClub club;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = club.photoPath;
    final letter = Container(
      key: const Key('club-avatar-letter'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: L360Colors.forest700, shape: BoxShape.circle),
      child: Text(
        club.initial,
        style: TextStyle(color: Colors.white, fontSize: size * 0.42, fontWeight: FontWeight.w700),
      ),
    );
    if (path == null) return letter;
    return ClipOval(
      child: Image.network(
        ref.watch(communityPhotoUrlProvider)(path),
        key: const Key('club-avatar-photo'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => letter,
      ),
    );
  }
}

/// The contact as a link when it looks like one (Instagram, site, WhatsApp), else as text
class ClubContact extends StatelessWidget {
  const ClubContact({super.key, required this.contact});

  final String contact;

  @override
  Widget build(BuildContext context) {
    final href = contactHref(contact);
    const style = TextStyle(fontSize: 13, color: L360Colors.sand700);
    return Row(
      children: [
        const Icon(Icons.contact_phone_outlined, size: 16, color: L360Colors.sand600),
        const SizedBox(width: 6),
        Expanded(
          child: href == null
              ? Text(contact, style: style)
              : InkWell(
                  key: const Key('club-contact-link'),
                  onTap: () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication),
                  child: Text(
                    contact,
                    style: style.copyWith(color: L360Colors.forest700, decoration: TextDecoration.underline),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ClubForm extends ConsumerStatefulWidget {
  const _ClubForm({this.club});

  final CommunityClub? club;

  @override
  ConsumerState<_ClubForm> createState() => _ClubFormState();
}

class _ClubFormState extends ConsumerState<_ClubForm> {
  late final _name = TextEditingController(text: widget.club?.name ?? '');
  late final _description = TextEditingController(text: widget.club?.description ?? '');
  late final _region = TextEditingController(text: widget.club?.region ?? '');
  late final _contact = TextEditingController(text: widget.club?.contact ?? '');
  CompressedPhoto? _photo; // a new photo to upload
  bool _removePhoto = false;
  bool _saving = false;
  bool _picking = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _description, _region, _contact]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final raw = await ref.read(communityPhotoPickerProvider)(ImageSource.gallery);
      if (raw == null) return;
      final photo = await ref.read(clubPhotoCompressorProvider)(raw);
      if (mounted) {
        setState(() {
          _photo = photo;
          _removePhoto = false;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    final problem = clubInputError(
      name: _name.text,
      description: _description.text,
      region: _region.text,
      contact: _contact.text,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(communityRepositoryProvider);
      final club = widget.club;
      if (club == null) {
        final id = await repo.createClub(_name.text, _description.text);
        // Home base and contact are part of the profile, saved right after
        if (_region.text.trim().isNotEmpty || _contact.text.trim().isNotEmpty) {
          await repo.updateClub(
            id,
            name: _name.text,
            description: _description.text,
            region: _region.text,
            contact: _contact.text,
          );
        }
        ref.invalidate(communityLimitsProvider);
      } else {
        await repo.updateClub(
          club.id,
          name: _name.text,
          description: _description.text,
          region: _region.text,
          contact: _contact.text,
        );
        final userId = ref.read(authUserIdProvider).value;
        if (userId != null && (_photo != null || _removePhoto)) {
          await repo.setClubPhoto(userId, club.id, _removePhoto ? null : _photo);
        }
      }
      ref.invalidate(myClubsProvider);
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      ref.invalidate(myClubsProvider);
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final club = widget.club;
    final hasPhoto = !_removePhoto && (_photo != null || club?.photoPath != null);
    return Padding(
      key: const Key('club-form'),
      padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              club == null ? 'New club' : 'Edit club',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (club != null) ...[
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (_photo != null)
                    ClipOval(child: Image.memory(_photo!.bytes, width: 56, height: 56, fit: BoxFit.cover))
                  else
                    ClubAvatar(
                      club: _removePhoto
                          ? CommunityClub(id: club.id, name: club.name, role: club.role, createdAt: club.createdAt)
                          : club,
                      size: 56,
                    ),
                  TextButton.icon(
                    key: const Key('club-photo-change'),
                    onPressed: _picking || _saving ? null : _pickPhoto,
                    icon: _picking
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.photo_outlined, size: 18),
                    label: Text(hasPhoto ? 'Change photo' : 'Add photo'),
                  ),
                  if (hasPhoto)
                    TextButton(
                      key: const Key('club-photo-remove'),
                      style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                              _photo = null;
                              _removePhoto = club.photoPath != null;
                            }),
                      child: const Text('Remove'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              key: const Key('club-name'),
              controller: _name,
              maxLength: clubNameMax,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name *', hintText: 'e.g. Mapala Gunung Gede'),
            ),
            TextField(
              key: const Key('club-about'),
              controller: _description,
              maxLength: clubDescriptionMax,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'About the club'),
            ),
            TextField(
              key: const Key('club-region'),
              controller: _region,
              maxLength: clubRegionMax,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Home base', hintText: 'e.g. Bogor, Jawa Barat'),
            ),
            TextField(
              key: const Key('club-contact'),
              controller: _contact,
              maxLength: clubContactMax,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Contact', hintText: '@instagram, website or 08…'),
            ),
            if (_error != null) ...[const SizedBox(height: 8), ErrorBanner(_error!)],
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('club-save'),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(club == null ? 'Create club' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
