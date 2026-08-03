import Foundation

// `tally add` - logging one more provider account into the next free numbered config home. Split
// out of main.swift purely for file size (same reason as UpdateCommand.swift).
//
// Only the terminal's half lives here. Picking the slot, creating the home, sharing the harness and
// seeding folder trust are Tally/Core/AddAccount.swift, which the app compiles too: Settings has its
// own "Add account" flow, and the two surfaces must prepare an account identically.

/// `tally add claude|codex`: create the next numbered config home and hand this terminal to the
/// official login flow.
///
/// Sharing is the DEFAULT (opt out with --no-share): before the login, the main account's harness is
/// symlinked into the new home - one set of instructions/skills/hooks/agents/settings maintained
/// once, and one conversation record, so cross-account resume and handoff continue the same history.
/// Multi-account in Tally means one person's accounts working as one fleet; separate setups are the
/// special case, not the default. The launch report says out loud when conversations are shared.
func runAdd(args: [String]) -> Never {
    let share = !args.contains("--no-share")
    let providerID = args.first { !$0.hasPrefix("--") } ?? ""
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("usage: tally add <claude|codex> [--no-share]")
        exit(2)
    }
    let prepared: AddedAccountHome
    do {
        prepared = try prepareAddedAccountHome(providerID: provider.id, share: share)
    } catch AddAccountFailure.noFreeSlot(let base) {
        warn("no free slot: ~/\(base) through ~/\(base)99 all have logins")
        exit(1)
    } catch AddAccountFailure.couldNotCreateHome(let path) {
        warn("could not create \(path) - check permissions; nothing was changed")
        exit(1)
    } catch {
        warn("could not prepare a config home: \(error)")
        exit(1)
    }
    if !prepared.unlinked.isEmpty {
        warn("share opted out - removed earlier share links: \(prepared.unlinked.joined(separator: ", "))")
    }
    if prepared.trustCleared > 0 {
        warn("share opted out - removed folder trust an earlier shared attempt seeded here (\(prepared.trustCleared) project\(prepared.trustCleared == 1 ? "" : "s"))")
    }
    if share {
        if prepared.isMainHome {
            warn("share skipped: ~/\(prepared.name) IS the main account (nothing to link yet)")
        } else {
            if !prepared.linked.isEmpty {
                warn("sharing the main account's harness: \(prepared.linked.joined(separator: ", "))")
            }
            if !prepared.kept.isEmpty {
                warn("left as-is (already present): \(prepared.kept.joined(separator: ", "))")
            }
            if !prepared.failed.isEmpty {
                warn("could not link: \(prepared.failed.joined(separator: ", ")) - check permissions; the share is incomplete")
            }
            if prepared.sharesConversations {
                warn("note: \(conversationEntry(provider.id))/ is shared - every account can read every account's conversations (next time: --no-share)")
            }
            if prepared.trustSeeded > 0 {
                warn("carried over folder trust for \(prepared.trustSeeded) project\(prepared.trustSeeded == 1 ? "" : "s")")
            }
        }
    }
    warn("adding a \(provider.id) account at ~/\(prepared.name) - finish the login below; the account shows up in Tally as soon as the login completes")
    exec(provider.cli, args: provider.id == "codex" ? ["login"] : [],
         env: launchEnv(provider, home: prepared.dir.path))
}
