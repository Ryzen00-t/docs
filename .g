name: Repo Sync

# **What it does**: GitHub Docs has two repositories: github/docs (public) and github/docs-internal (private).
# This GitHub Actions workflow keeps the `main` branch of those two repos in sync.
# **Why we have it**: To keep the open-source repository up-to-date
# while still having an internal repository for sensitive work.
# **Who does it impact**: Open-source.
# For more details, see https://github.com/repo-sync/repo-sync#how-it-works

on:
  workflow_dispatch:
  schedule:
    - cron: '20 */3 * * *' # Run every 3rd hour at 20 minutes after

permissions:
  contents: write
  pull-requests: write

jobs:
  repo-sync:
    if: github.repository == 'github/docs-internal' || github.repository == 'github/docs'
    name: Ryzen00-t/docs
    runs-on: ubuntu-latest
    steps:
      - name: Check out repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Sync repo to branch
        uses: repo-sync/github-sync@3832fe8e2be32372e1b3970bbae8e7079edeec88
        with:
          source_repo: https://${{ secrets.DOCS_BOT_PAT_REPO_SYNC }}@github.com/github/${{ github.repository == 'github/docs-internal' && 'docs' || 'docs-internal' }}.git
          source_branch: main
          destination_branch: repo-sync
          github_token: ${{ secrets.DOCS_BOT_PAT_REPO_SYNC }}

      - name: Ship pull request
        uses: actions/github-script@e69ef5462fd455e02edcaf4dd7708eda96b9eda0
        with:
          github-token: ${{ secrets.DOCS_BOT_PAT_REPO_SYNC }}
          result-encoding: string
          script: |
            const { owner, repo } = context.repo
            const head = 'github:repo-sync'
            const base = 'main'

            async function closePullRequest(prNumber) {
              console.log('Closing pull request', prNumber)
              await github.rest.pulls.update({
                owner,
                repo,
                pull_number: prNumber,
                state: 'closed'
              })
              // Error loud here, so no try/catch
              console.log('Closed pull request', prNumber)
            }

            console.log('Closing any existing pull requests')
            const { data: existingPulls } = await github.rest.pulls.list({ owner, repo, head, base })
            if (existingPulls.length) {
              console.log('Found existing pull requests', existingPulls.map(pull => pull.number))
              for (const pull of existingPulls) {
                await closePullRequest(pull.number)
              }
              console.log('Closed existing pull requests')
            }

            try {
              const { data } = await github.rest.repos.compareCommits({
                owner,
                repo,
                head,
                base,
              })
              const { files } = data
              console.log(`File changes between ${head} and ${base}:`, files)
              if (!files.length) {
                console.log('No files changed, bailing')
                return
              }
            } catch (err) {
              console.error(`Unable to compute the files difference between ${head} and ${base}`, err.message)
            }

            console.log('Creating a new pull request')
            const body = `
            This is an automated pull request to sync changes between the public and private repos.
            Our bot will merge this pull request automatically.
            To preserve continuity across repos, _do not squash_ this pull request.
            `
            let pull, pull_number
            try {
              const response = await github.rest.pulls.create({
                owner,
                repo,
                head,
                base,
                title: 'Repo sync',
                body,
              })
              pull = response.data
              pull_number = pull.number
              console.log('Created pull request successfully', pull.html_url)
            } catch (err) {
              // Don't error/alert if there's no commits to sync
              // Don't throw if > 100 pulls with same head_sha issue
              if (err.message?.includes('No commits') || err.message?.includes('same head_sha')) {
                console.log(err.message)
                return
              }
              throw err
            }

            console.log('Locking conversations to prevent spam')
            try {
              await github.rest.issues.lock({
                ...context.repo,
                issue_number: pull_number,
                lock_reason: 'spam'
              })
              console.log('Locked the pull request to prevent spam')
            } catch (error) {
              console.error('Failed to lock the pull request.', error)
              // Don't fail the workflow
            }

            console.log('Counting files changed')
            const { data: prFiles } = await github.rest.pulls.listFiles({ owner, repo, pull_number })
            if (prFiles.length) {
              console.log(prFiles.length, 'files have changed')
            } else {
              console.log('No files changed, closing')
              await closePullRequest(pull_number)
              return
            }

            console.log('Checking for merge conflicts')
            if (pull.mergeable_state === 'dirty') {
              console.log('Pull request has a conflict', pull.html_url)
              await closePullRequest(pull_number)
              throw new Error('Pull request has a conflict, please resolve manually')
            }
            console.log('No detected merge conflicts')

            console.log('Merging the pull request')
            // Admin merge pull request to avoid squash
            await github.rest.pulls.merge({
              owner,
              repo,
              pull_number,
              merge_method: 'merge',
            })
            // Error loud here, so no try/catch
            console.log('Merged the pull request successfully')

      - uses: ./.github/actions/slack-alert
        if: ${{ failure() && github.event_name != 'workflow_dispatch' }}
        with:
          slack_channel_id: ${{ secrets.DOCS_ALERTS_SLACK_CHANNEL_ID }}
          slack_token: ${{ secrets.SLACK_DOCS_BOT_TOKEN }}
