//
//  GroupCallInv.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 12.12.2020.
//  Copyright © 2020 Telegram. All rights reserved.
//

import Foundation
import TGUIKit
import SwiftSignalKit
import Postbox
import SyncCore
import TelegramCore

private final class InvitationArguments {
    let account: Account
    let copyLink: (String)->Void
    let inviteGroupMember:(PeerId)->Void
    let inviteContact:(PeerId)->Void
    init(account: Account, copyLink: @escaping(String)->Void, inviteGroupMember:@escaping(PeerId)->Void, inviteContact:@escaping(PeerId)->Void) {
        self.account = account
        self.copyLink = copyLink
        self.inviteGroupMember = inviteGroupMember
        self.inviteContact = inviteContact
    }
}

private struct InvitationPeer : Equatable {
    let peer: Peer
    let presence: PeerPresence?
    let contact: Bool
    let enabled: Bool
    static func ==(lhs:InvitationPeer, rhs: InvitationPeer) -> Bool {
        if !lhs.peer.isEqual(rhs.peer) {
            return false
        }
        if let lhsPresence = lhs.presence, let rhsPresence = rhs.presence {
            return lhsPresence.isEqual(to: rhsPresence)
        } else if (lhs.presence != nil) != (rhs.presence != nil) {
            return false
        }
        if lhs.contact != rhs.contact {
            return false
        }
        if lhs.enabled != rhs.enabled {
            return false
        }
        return true
    }
}


final class GroupCallAddMembersBehaviour : SelectPeersBehavior {
    fileprivate let data: GroupCallUIController.UIData
    private let disposable = MetaDisposable()
    init(data: GroupCallUIController.UIData) {
        self.data = data
        super.init(settings: [], excludePeerIds: [], limit: 1, customTheme: { GroupCallTheme.customTheme })
    }
    
    private let cachedContacts:Atomic<[PeerId]> = Atomic(value: [])
    func isContact(_ peerId: PeerId) -> Bool {
        return cachedContacts.with {
            $0.contains(peerId)
        }
    }
    
    override func start(account: Account, search: Signal<SearchState, NoError>, linkInvation: (() -> Void)? = nil) -> Signal<([SelectPeerEntry], Bool), NoError> {
        
        
        let peerMemberContextsManager = data.peerMemberContextsManager
        let account = data.call.account
        let peerId = data.call.peerId
        let customTheme = self.customTheme
        let cachedContacts = self.cachedContacts
        let members = data.call.members |> filter { $0 != nil } |> map { $0! }
        let invited = data.call.invitedPeers
        return search |> mapToSignal { search in
            var contacts:Signal<([Peer], [PeerId : PeerPresence]), NoError>
            if search.request.isEmpty {
                contacts = account.postbox.contactPeersView(accountPeerId: account.peerId, includePresences: true) |> map {
                    return ($0.peers, $0.peerPresences)
                }
            } else {
                contacts = account.postbox.searchContacts(query: search.request)
            }
            contacts = combineLatest(account.postbox.peerView(id: peerId), contacts) |> map { peerView, contacts in
                if let peer = peerViewMainPeer(peerView) {
                    if peer.groupAccess.canAddMembers {
                        return contacts
                    } else {
                        return ([], [:])
                    }
                } else {
                    return ([], [:])
                }
            }
            let groupMembers:Signal<[RenderedChannelParticipant], NoError> = Signal { subscriber in
                let (disposable, _) = peerMemberContextsManager.recent(postbox: account.postbox, network: account.network, accountPeerId: account.peerId, peerId: peerId, searchQuery: search.request.isEmpty ? nil : search.request, updated:  { state in
                    if case .ready = state.loadingState {
                        subscriber.putNext(state.list)
                        subscriber.putCompletion()
                    }
                })
                return disposable
            }
            
            
            let allMembers: Signal<([InvitationPeer], [InvitationPeer]), NoError> = combineLatest(groupMembers, members, contacts, invited) |> map { recent, participants, contacts, invited in
                let membersList = recent.filter { value in
                    if participants.participants.contains(where: { $0.peer.id == value.peer.id }) {
                        return false
                    }
                    return !value.peer.isBot
                }.map {
                    InvitationPeer(peer: $0.peer, presence: $0.presences[$0.peer.id], contact: false, enabled: !invited.contains($0.peer.id))
                }
                var contactList:[InvitationPeer] = []
                for contact in contacts.0 {
                    let containsInCall = participants.participants.contains(where: { $0.peer.id == contact.id })
                    let containsInMembers = membersList.contains(where: { $0.peer.id == contact.id })
                    if !containsInMembers && !containsInCall {
                        contactList.append(InvitationPeer(peer: contact, presence: contacts.1[contact.id], contact: true, enabled: !invited.contains(contact.id)))
                    }
                }
                _ = cachedContacts.swap(contactList.map { $0.peer.id })
                return (membersList, contactList)
            }
            
            let inviteLink: Signal<String?, NoError> = account.viewTracker.peerView(peerId) |> map { peerView in
                if let peer = peerViewMainPeer(peerView), let cachedData = peerView.cachedData as? CachedChannelData {
                    if let addressName = peer.addressName, !addressName.isEmpty {
                        return "https://t.me/@\(addressName)"
                    } else if let privateLink = cachedData.exportedInvitation {
                        return privateLink.link
                    }
                }
                return nil
            }
            
            let previousSearch: Atomic<String> = Atomic<String>(value: "")
            return combineLatest(allMembers, inviteLink) |> map { members, inviteLink in
                var entries:[SelectPeerEntry] = []
                var index:Int32 = 0
                if let inviteLink = inviteLink, search.request.isEmpty {
                    entries.append(.inviteLink(L10n.voiceChatInviteCopyInviteLink, customTheme(), {
                        copyToClipboard(inviteLink)
                        linkInvation?()
                    }))
                }
                
                if !members.0.isEmpty  {
                    entries.append(.separator(index, customTheme(), L10n.voiceChatInviteGroupMembers))
                    index += 1
                }
                
                for member in members.0 {
                    entries.append(.peer(SelectPeerValue(peer: member.peer, presence: member.presence, subscribers: nil, customTheme: customTheme()), index, member.enabled))
                    index += 1
                }
                
                if !members.1.isEmpty {
                    entries.append(.separator(index, customTheme(), L10n.voiceChatInviteContacts))
                    index += 1
                }
                
                for member in members.1 {
                    entries.append(.peer(SelectPeerValue(peer: member.peer, presence: member.presence, subscribers: nil, customTheme: customTheme()), index, member.enabled))
                    index += 1
                }
                
                let updatedSearch = previousSearch.swap(search.request) != search.request
                
                if entries.isEmpty {
                    entries.append(.searchEmpty)
                }
                
                return (entries, updatedSearch)
            }
        }
        
        
    }
    
    
}

func GroupCallAddmembers(_ data: GroupCallUIController.UIData, window: Window) -> Signal<[PeerId], NoError> {
    
    let behaviour = GroupCallAddMembersBehaviour(data: data)
    let account = data.call.account
    let callPeerId = data.call.peerId
    let peerMemberContextsManager = data.peerMemberContextsManager

    
    return selectModalPeers(window: window, account: data.call.account, title: L10n.voiceChatInviteTitle, settings: [], excludePeerIds: [], limit: 1, behavior: behaviour, confirmation: { [weak behaviour, weak window] peerIds in
        
        guard let peerId = peerIds.first, let behaviour = behaviour, let window = window else {
            return .single(true)
        }
        if behaviour.isContact(peerId) {
            return account.postbox.transaction {
                return (user: $0.getPeer(peerId), chat: $0.getPeer(callPeerId))
            } |> mapToSignal { values in
                return confirmSignal(for: window, information: L10n.voiceChatInviteMemberToGroupFirstText(values.user?.displayTitle ?? "", values.chat?.displayTitle ?? ""), okTitle: L10n.voiceChatInviteMemberToGroupFirstAdd, appearance: darkPalette.appearance) |> filter { $0 }
                    |> take(1)
                |> mapToSignal { _ in
                    return peerMemberContextsManager.addMember(account: account, peerId: callPeerId, memberId: peerId) |> map { _ in
                        return true
                    }
                }
                
            }
        } else {
            return .single(true)
        }
        
    }, linkInvation: { [weak window] in
        if let window = window {
            _ = showModalSuccess(for: window, icon: theme.icons.successModalProgress, delay: 2.0).start()
        }
    })
    
}