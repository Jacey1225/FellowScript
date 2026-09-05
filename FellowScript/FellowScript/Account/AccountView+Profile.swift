// AccountView+Profile.swift — profile header, stats overview, plan-usage
// display, edit-profile form, and friend requests. Split out of
// AccountView.swift (readability #6, 20260904-frontend-arch-sweep) -- same
// type, same behavior, just this section's own file. See AccountView.swift's
// header comment for the full split rationale and the list of sibling
// section files.

import SwiftUI
import PhotosUI

// Task 20260905-profile-photo: mirrors api/backend/interactions/attachments.py's
// PER_KIND_LIMITS["image"] (reused verbatim by the backend for profile
// photos) -- advisory client-side pre-flight only, matching the web
// client's identically-named PHOTO_LIMITS in Account.jsx; real enforcement
// is the presigned POST policy's content-length-range condition, S3-side.
enum ProfilePhotoLimits {
    static let maxBytes = 15 * 1024 * 1024
    static let allowedContentTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic"]
    static let oversizeCopy = "Photos can be up to 15MB."
    static let unsupportedTypeCopy = "That file type isn't supported here."
}

extension AccountView {

    // ── Section builders ───────────────────────────────────────────────────────

    var profileHeader: some View {
        VStack(spacing: Theme.spacingSM) {
            // Task 20260905-profile-photo: the existing initials circle
            // stays as the permanent base layer (and thus the fallback
            // whenever there's no photo, one is still loading, or a load
            // fails) -- a real photo, once resolved, crossfades in on top
            // via AsyncImage's own `transaction:` (Q17/Q18), and a plain
            // spinner scrim covers both while an upload is in flight.
            PhotosPicker(selection: $photoPickerItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: "#EDAB3C").opacity(0.32), Color(hex: "#B8761D").opacity(0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                        Text(appState.currentUser?.initials ?? "?")
                            .font(.playfair(Theme.fontDisplayMD))
                            .foregroundColor(Theme.goldLight)
                        if let photoURL = vm.profileData?.profile_photo_url, !photoURL.isEmpty,
                           let url = URL(string: photoURL) {
                            AsyncImage(
                                url: url,
                                transaction: Transaction(animation: reduceMotion ? nil : .easeIn(duration: 0.25))
                            ) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipShape(Circle())
                                        .transition(.opacity)
                                }
                            }
                        }
                        if photoUploading {
                            Circle().fill(Color.black.opacity(0.45)).frame(width: 72, height: 72)
                            ProgressView().tint(.white)
                        }
                    }
                    .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1.5))
                    // Small, functional (not decorative) confirmation pulse
                    // alongside the crossfade above once an upload/removal
                    // actually lands (Q18) -- skipped entirely under Reduce
                    // Motion rather than substituted with something else,
                    // since the crossfade/VoiceOver announcement already
                    // communicate the same state change.
                    .scaleEffect(photoJustUpdated && !reduceMotion ? 1.05 : 1.0)
                    .motionAwareAnimation(.easeOut(duration: 0.2), value: photoJustUpdated, reduceMotion: reduceMotion)

                    // Edit affordance badge -- gold-on-ink comfortably clears
                    // AA contrast at this weight/size (Q14).
                    ZStack {
                        Circle().fill(Theme.gold)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.ink)
                    }
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Theme.bgPage, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .disabled(photoUploading)
            .accessibilityLabel(vm.profileData?.profile_photo_url == nil ? "Add a profile photo" : "Change profile photo")
            .onChange(of: photoPickerItem) { _, newItem in
                handlePhotoPicked(newItem)
            }

            if vm.profileData?.profile_photo_url != nil {
                Button(action: removePhoto) {
                    Text("Remove photo")
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                }
                .disabled(photoUploading)
                .accessibilityLabel("Remove profile photo")
            }

            if let photoError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(photoError).font(.inter(Theme.fontSM))
                }
                .foregroundColor(Theme.error)
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                .background(Theme.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            VStack(spacing: 4) {
                Text(vm.profileData?.username ?? "")
                    .font(.playfair(Theme.fontDisplayMD))
                    .foregroundColor(Theme.parchment)
                Text(vm.profileData?.email ?? "")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.top, Theme.spacingXS)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingMD)
    }

    // ── Profile photo (task 20260905-profile-photo) ───────────────────────────
    // Same three-step wire contract as the web client's Account.jsx and this
    // app's own existing message-attachment upload flow (request a presigned
    // S3 POST policy over plain HTTP, upload the raw bytes directly to S3
    // with it, then confirm) -- this server never receives the photo bytes
    // themselves.

    private func handlePhotoPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoError = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                photoError = "Could not read that photo. Please try again."
                return
            }
            let contentType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            await uploadPhoto(data: data, contentType: contentType)
            // Clear the selection so re-picking the exact same photo still
            // fires onChange (PhotosPickerItem doesn't otherwise change).
            photoPickerItem = nil
        }
    }

    private func uploadPhoto(data: Data, contentType: String) async {
        guard let uid = appState.currentUser?.user_id else { return }
        guard data.count <= ProfilePhotoLimits.maxBytes else {
            photoError = ProfilePhotoLimits.oversizeCopy
            return
        }
        guard ProfilePhotoLimits.allowedContentTypes.contains(contentType) else {
            photoError = ProfilePhotoLimits.unsupportedTypeCopy
            return
        }
        photoUploading = true
        defer { photoUploading = false }
        do {
            let uploadInfo = try await appState.service.requestProfilePhotoUploadURL(
                userId: uid, contentType: contentType, sizeBytes: data.count
            )
            try await appState.service.uploadAttachment(fileData: data, contentType: contentType, uploadInfo: uploadInfo)
            let photoURL = try await appState.service.confirmProfilePhoto(userId: uid, objectKey: uploadInfo.object_key)
            applyPhotoUpdate(photoURL)
            // The visual crossfade already happens via AsyncImage's own
            // `transaction:` above (Q18) -- this flag additionally posts a
            // VoiceOver announcement so the state change is communicated
            // non-visually too, not just decoratively.
            photoJustUpdated = true
            UIAccessibility.post(notification: .announcement, argument: "Profile photo updated.")
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                photoJustUpdated = false
            }
        } catch {
            photoError = (error as? LocalizedError)?.errorDescription ?? "Could not reach the server."
        }
    }

    func removePhoto() {
        guard let uid = appState.currentUser?.user_id else { return }
        photoError = nil
        photoUploading = true
        Task {
            do {
                try await appState.service.removeProfilePhoto(userId: uid)
                applyPhotoUpdate(nil)
                UIAccessibility.post(notification: .announcement, argument: "Profile photo removed.")
            } catch {
                photoError = (error as? LocalizedError)?.errorDescription ?? "Could not remove your photo. Please try again."
            }
            photoUploading = false
        }
    }

    /// Updates both `appState.currentUser` (so every other already-open
    /// screen sourcing its avatar from it -- HeroHeader, MessageGroupRow's
    /// outgoing bubbles -- reflects the change immediately) and this
    /// screen's own `vm.profileData`, mirroring `saveProfile()`'s identical
    /// dual-write below.
    private func applyPhotoUpdate(_ url: String?) {
        guard var updated = appState.currentUser else { return }
        updated.profile_photo_url = url
        appState.updateUser(updated)
        vm.profileData = updated
    }

    var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Overview")
            HStack {
                StatBox(value: vm.friendCount,    label: "Friends")
                StatBox(value: vm.groupCount,     label: "Groups")
                StatBox(value: vm.noteCount,      label: "Notes")
                StatBox(value: vm.highlightCount, label: "Verses")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    @ViewBuilder
    var usageSection: some View {
        if let usage = vm.usage {
            // The subscription record is authoritative; force "unlimited" when the
            // user has a paid plan even if this usage payload predates the sync.
            let unlimited = vm.hasUnlimitedPlan
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                sectionLabel("Plan Usage")
                usageRow("Notes", usage.notes, hint: "last \(usage.window_days) days", forceUnlimited: unlimited)
                Divider().background(Theme.borderGoldFaint)
                usageRow("Agent events", usage.agentEvents, hint: nil, forceUnlimited: unlimited)
                if !unlimited {
                    Divider().background(Theme.borderGoldFaint)
                    Text("You're on the free plan. Upgrade to a Group plan for unlimited notes and events.")
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textGoldMuted)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassCard(cornerRadius: 20)
        }
    }

    func usageRow(_ label: String, _ r: FSUsageResource, hint: String?, forceUnlimited: Bool) -> some View {
        let unlimited = forceUnlimited || r.unlimited
        return VStack(alignment: .leading, spacing: Theme.spacingXS + 2) {
            HStack(spacing: Theme.spacingSM) {
                Text(label)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                if let hint, !unlimited {
                    Text(hint)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Text(unlimited ? "Unlimited" : "\(r.used) / \(r.limit)")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(unlimited ? Theme.gold : (r.maxedOut ? Theme.error : Theme.textGoldMuted))
            }
            if !unlimited {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.parchment.opacity(0.12))
                        Capsule()
                            .fill(r.maxedOut ? Theme.error : Theme.gold)
                            .frame(width: max(3, geo.size.width * r.fraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.vertical, Theme.spacingXS)
    }

    var editProfileSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Edit Profile")

            // Edit message
            if let msg = vm.editMsg {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: msg.type == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(msg.text)
                        .font(.inter(Theme.fontSM))
                }
                .foregroundColor(msg.type == .success ? Theme.success : Theme.error)
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                .background((msg.type == .success ? Theme.success : Theme.error).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            // Username
            HStack {
                Image(systemName: "person").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Username", text: $username)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .autocapitalization(.none)
                    .accessibilityLabel("Username field")
            }
            Divider().background(Theme.borderGoldFaint)

            // Email
            HStack {
                Image(systemName: "envelope").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                TextField("Email", text: $email)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .accessibilityLabel("Email field")
            }
            Divider().background(Theme.borderGoldFaint)

            // Timezone — opens a searchable picker sheet; drives the nightly
            // backup schedule (it runs at this timezone's local 3am).
            Button(action: { activeSheet = .timezonePicker }) {
                HStack {
                    Image(systemName: "clock").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                    Text("Timezone")
                        .font(.inter(Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    Spacer()
                    Text(timezone)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.textGoldMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textGoldMuted)
                }
            }
            .accessibilityLabel("Timezone: \(timezone)")
            Divider().background(Theme.borderGoldFaint)

            // Password
            HStack {
                Image(systemName: "lock").foregroundColor(Theme.textGoldMuted).frame(width: 22)
                SecureField("New Password (leave blank to keep)", text: $password)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("New password field")
            }
            Divider().background(Theme.borderGoldFaint)

            Button(action: saveProfile) {
                gradientPill("Save Changes")
            }
            .accessibilityLabel("Save profile changes")
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
    }

    var friendRequestsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Friend Requests")

            if let msg = vm.friendMsg {
                Text(msg)
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.error)
                    .padding(.horizontal, Theme.spacingSM).padding(.vertical, Theme.spacingXS + 2)
                    .background(Theme.error.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }

            if vm.friendRequests.isEmpty {
                Text("No pending friend requests.")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(Array(vm.friendRequests.enumerated()), id: \.offset) { idx, req in
                    if idx > 0 { Divider().background(Theme.borderGoldFaint) }
                    HStack {
                        ZStack {
                            Circle().fill(Theme.gold.opacity(0.15)).frame(width: 36, height: 36)
                            Text(String(req.username.prefix(1)).uppercased())
                                .font(.playfair(Theme.fontSM)).foregroundColor(Theme.gold)
                        }
                        VStack(alignment: .leading) {
                            Text(req.username).font(.inter(Theme.fontBody)).foregroundColor(Theme.parchment)
                            Text("Wants to be your friend").font(.inter(Theme.fontXS)).foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                        Button {
                            Task { await vm.acceptRequest(username: req.username) }
                        } label: {
                            gradientPill("Accept", compact: true)
                        }
                        .accessibilityLabel("Accept friend request from \(req.username)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 16)
        .glassCard(cornerRadius: 20)
        // Test-only hook (no visual/behavioral effect): lets AccountUITests
        // measure this card's rendered frame width to prove it matches its
        // sibling sections instead of shrink-wrapping around a short empty-state
        // string. See test_friendRequestsSection_emptyState_matchesAvailableContentWidth.
        // .accessibilityElement(children: .combine) is required alongside the
        // identifier below — without it, a bare identifier on a plain (non-
        // accessibility-element) VStack gets pushed down onto each descendant
        // leaf individually instead of producing one queryable otherElements
        // container, which is what the test actually looks up.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Friend Requests card")
    }

    func saveProfile() {
        guard let user = appState.currentUser else { return }
        var body: [String: String] = [:]
        if !username.isEmpty && username != user.username { body["username"] = username }
        if !email.isEmpty    && email    != user.email    { body["email"]    = email    }
        if !password.isEmpty                              { body["plain_pass"] = password }
        if timezone != user.timezone                      { body["timezone"]   = timezone }
        Task {
            do {
                let updated = try await appState.service.updateUser(userId: user.user_id, body: body)
                appState.updateUser(updated)
                vm.profileData = updated
                vm.editMsg = (.success, "Profile updated.")
            } catch {
                // Never show "Profile updated." on a failed save — surface the
                // real error instead so a rejected/failed write is visible.
                vm.editMsg = (.error, error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            vm.editMsg = nil
        }
        password = ""
    }
}
