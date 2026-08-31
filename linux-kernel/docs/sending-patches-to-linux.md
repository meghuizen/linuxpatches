# How to send a patch to the Linux kernel for review

This is a short, practical guide. It covers the normal path: you change some
kernel code, turn the change into a patch, and email it to the right people.

The official, longer documents are in the kernel source tree:

- `Documentation/process/submitting-patches.rst` (the main one)
- `Documentation/process/5.Posting.rst`
- `Documentation/process/email-clients.rst`

If this guide and the official docs disagree, the official docs win.

## Before you start

You need three things:

1. A git clone of the right kernel tree.
2. A working plain text email setup (`git send-email`).
3. Your real name and a real email address. The kernel requires a real name
   for the `Signed-off-by` line. No nicknames, no anonymous addresses.

## Step 1: Work on the right tree

Do not just clone Linus' tree and hope. Most subsystems have their own tree,
and your patch must apply cleanly there.

Start with mainline:

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
```

Then check whether the subsystem you are touching has its own tree. Look it
up in the `MAINTAINERS` file, or ask on the subsystem mailing list. For most
small fixes, mainline or `linux-next` is fine.

Make a branch for your work:

```sh
git checkout -b my-fix
```

## Step 2: Make one change per commit

This is the rule people break most often.

- One commit = one logical change.
- If your commit message needs the word "and", it is probably two commits.
- Every commit in a series must build and boot on its own. A reviewer must be
  able to stop halfway through your series and still have a working kernel.

Do not mix a whitespace cleanup with a bug fix. Send them as two patches.

## Step 3: Write a good commit message

Format:

```
subsystem: short summary in the imperative mood

Explain what problem this solves and why. Describe the behaviour before
and after. Say how you tested it. Wrap lines at about 75 characters.

Do not explain what the code does line by line. The diff already shows
that. Explain the *why*.

Fixes: 1234567890ab ("the subject of the broken commit")
Signed-off-by: Your Name <you@example.com>
```

Rules for the subject line:

- Start with the subsystem prefix, then a colon. Look at `git log` for the
  files you touched to see the prefix that subsystem uses.
- Use the imperative mood: "fix the leak", not "fixed the leak" or
  "this fixes the leak".
- Keep it under about 70 characters, and do not end it with a period.

Useful tags at the bottom:

- `Fixes: <12-char sha> ("<subject>")` - the commit that introduced the bug.
- `Cc: stable@vger.kernel.org` - only if the fix should go into stable
  kernels. Read `Documentation/process/stable-kernel-rules.rst` first.
- `Reported-by:`, `Tested-by:`, `Reviewed-by:` - credit other people. Only
  add these if that person actually gave them to you.

### About Signed-off-by

`Signed-off-by` is a legal statement, not a signature. By adding it you say
you have the right to submit the code under the kernel licence. The full
text is the Developer Certificate of Origin, in
`Documentation/process/submitting-patches.rst`.

Add it automatically:

```sh
git commit -s
```

A patch without `Signed-off-by` will be rejected.

## Step 4: Check your patch

The kernel ships a script that catches most style mistakes. Run it before
you send anything:

```sh
./scripts/checkpatch.pl --strict -g HEAD
```

Fix everything it reports. If you think a warning is wrong, say so in the
patch description so reviewers know it was on purpose.

Also build the code you changed, and test it. "It compiles" is not testing.

## Step 5: Turn commits into patch files

For a single patch:

```sh
git format-patch -1
```

For a series of three patches, with a cover letter:

```sh
git format-patch -3 --cover-letter
```

This writes files like `0000-cover-letter.patch`, `0001-....patch`. Open the
cover letter and replace the `SUBJECT HERE` and `BLURB HERE` placeholders.
The cover letter explains the series as a whole: what problem it solves and
how the patches fit together.

A cover letter is required for a series. For a single patch, skip it.

## Step 6: Find out who to send it to

Never guess the recipients. The kernel has a script for this:

```sh
./scripts/get_maintainer.pl 0001-my-fix.patch
```

It prints maintainers, reviewers, and mailing lists, based on the files you
touched. Send:

- **To:** the maintainers.
- **Cc:** the reviewers, the subsystem mailing list, and
  `linux-kernel@vger.kernel.org`.

Do not send to a huge list of unrelated people. Do not send to Linus for a
normal patch.

## Step 7: Set up git send-email

Patches must arrive as plain text, inside the email body, not as an
attachment. Most graphical mail clients silently break patches by wrapping
lines or turning tabs into spaces. Use `git send-email`.

Install it (Debian/Ubuntu):

```sh
sudo apt install git-email
```

Configure it once, in `~/.gitconfig`:

```ini
[user]
	name = Your Name
	email = you@example.com

[sendemail]
	smtpServer = smtp.example.com
	smtpServerPort = 587
	smtpEncryption = tls
	smtpUser = you@example.com
```

For Gmail you must create an app password; your normal password will not
work.

Always test first with a dry run:

```sh
git send-email --dry-run --to=you@example.com *.patch
```

Then really send it to yourself, and check that the patch you receive still
applies:

```sh
git am /path/to/received/mail
```

If that works, your setup is good.

## Step 8: Send it

```sh
git send-email \
  --to="Maintainer Name <maintainer@example.com>" \
  --cc="reviewer@example.com" \
  --cc="linux-subsystem@vger.kernel.org" \
  --cc="linux-kernel@vger.kernel.org" \
  *.patch
```

`git send-email` automatically threads a series under the cover letter, so
send all the files of a series in one command.

## Step 9: Wait, then handle the review

Maintainers are busy and often volunteers. Give it **at least one week**,
usually two, before you follow up. Do not ping after a day.

When you get review comments:

- Reply on the mailing list, in plain text, to everyone who was on the mail.
- Quote the part you are answering and write your reply **below** it. Do not
  put your answer at the top (no "top-posting").
- Answer every comment, even if it is only "will fix in v2".
- If you disagree, say why, politely and technically. Disagreeing is normal.
- Review comments are about the code, not about you.

## Step 10: Send a new version

Never send a fix as a reply with a new patch attached. Send a whole new
version of the series.

```sh
git format-patch -v2 -3 --cover-letter
```

This makes the subject `[PATCH v2 1/3] ...`. In the cover letter (or below
the `---` line of a single patch), add a changelog:

```
---
Changes in v2:
 - Fix the memory leak reported by X.
 - Split the whitespace cleanup into its own patch.
 - Rebase on top of v6.12-rc1.
```

Anything below the `---` line is not stored in git history. It is for
reviewers only. That is exactly where the changelog belongs.

Also carry over any `Reviewed-by:` or `Acked-by:` tags people gave you, for
the patches you did not change. Drop them for patches you did change.

## Step 11: After it is accepted

The maintainer applies your patch to their tree. From there it goes into
`linux-next` for testing, and then to Linus during the next merge window.
This takes weeks. That is normal, and you do not have to do anything.

## The easier way: b4

`b4` is a tool that automates most of the steps above. It prepares the
series, tracks versions, collects review tags for you, and sends the mail.

```sh
pip install b4

b4 prep -n my-fix -f v6.12      # start a new series
# ... make your commits ...
b4 prep --auto-to-cc            # fill in the recipients
b4 send --dry-run               # check
b4 send                         # send
```

For a second version, amend your commits and run `b4 send` again. It handles
the `v2` numbering and the changelog.

See <https://b4.docs.kernel.org/>.

## Common mistakes

| Mistake | Why it is a problem |
|---|---|
| Sending the patch as an attachment | Reviewers cannot quote or comment on it inline. |
| Using HTML email | Mailing lists reject it. |
| Missing `Signed-off-by` | The patch cannot be accepted, full stop. |
| One giant commit | Nobody can review it, so nobody will. |
| Guessing the recipients | Your patch never reaches the person who can apply it. |
| Not running `checkpatch.pl` | Wastes a review round on style instead of substance. |
| Pinging after one day | Reads as rude, and does not speed anything up. |
| Top-posting a reply | Makes the thread hard to follow; considered bad manners. |
| Sending v2 as a reply to v1 | Maintainer tooling expects a fresh series. |

## Where to look things up

- The mailing list archive: <https://lore.kernel.org/>. Search here to see
  how other people wrote patches for the same subsystem.
- The `MAINTAINERS` file in the kernel tree.
- <https://kernelnewbies.org/> - a friendly place to start.
- The Linux Kernel Mentorship Program, if you want a mentor.

Read a few weeks of your subsystem mailing list before you post. Copying
what the regulars do is the fastest way to get it right.
