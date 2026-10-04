# LemonSeed Studio privacy policy

Effective October 4, 2026.

LemonSeed Studio is an editor and IDE for iPad that runs language models on
an AMD GPU attached to the iPad. It does not collect, sell or share your
data, and it has no account of its own.

## What stays on your iPad

- **Models and chats.** Models run on the iPad and its attached GPU. Your
  prompts, the model's replies and your chat history are processed and
  stored on the iPad (chats are saved inside each project folder) and are
  never sent to us.
- **Your files and projects.** Files you open or create stay where you keep
  them. Studio sends them nowhere unless you push them to a Git remote.
- **Credentials.** Tokens you add (a Hugging Face access token, GitHub or
  GitLab sign-in) and SSH keys are stored in the iPad's Keychain.
- **GPU and driver information.** The GPU monitor and diagnostics read
  information from the GPU and its driver on the iPad and display it there.

## When Studio uses the network

Studio connects to the internet only to do something you asked for:

- **Downloading models** from Hugging Face (huggingface.co) when you browse,
  search or download a model. If you add a Hugging Face token, it is sent
  only to Hugging Face.
- **Git.** Cloning, fetching, pulling and pushing go to the remotes you
  configure, over HTTPS or SSH, including Git LFS on those servers.
- **GitHub and GitLab accounts.** If you sign in to GitHub or GitLab, Studio
  talks to that service (for example api.github.com, gitlab.com, or a
  server you enter) to sign you in and to show your repositories and pull
  requests.
- **Model endpoints you set up.** If you point Studio at a model server, such
  as lse-server on your Mac, requests go to that server.

What you send to these services is governed by their own privacy policies.

## What Studio does not do

- No analytics, advertising or tracking, and no third-party SDKs that do
  any of these.
- No crash reporting of its own. If you allow Apple to share crash data
  with developers, iPadOS handles that under Apple's privacy policy.
- No account, and no personal information collected by us.

## Contact

Questions about this policy: open an issue at
https://github.com/Geramy/LemonSeed-Studio/issues.
