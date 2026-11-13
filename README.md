# B2F Azure Templates

ARM templates and setup scripts for the Azure machines B2F uses. The repository is public because a
VM downloads its setup scripts from here during deployment without any credentials. **Never commit a
secret**: tokens and passwords are deployment parameters, never file content.

## Templates

| Folder | What it creates |
|---|---|
| [`buildagent/`](buildagent/README.md) | Windows Server 2022 build agent for Azure DevOps: Docker, BcContainerHelper, Claude Code, build tools, N agents |

## Layout

```
<template>/        one folder per template: the ARM template, its scripts and a README
shared/            scripts used by more than one template
```

## Releases

A template never downloads scripts from `main`. Its `scriptsBaseUrl` parameter points to a tag, so a
change in progress cannot break a deployment, and going back to an earlier version means using the
earlier tag.

Tags are per template: `buildagent-v1`, `buildagent-v2`, ... To release a change:

1. Merge it to `main`.
2. Update the tag in the template's `scriptsBaseUrl` default and in the deploy link of its README,
   and commit that.
3. Tag that commit: `git tag buildagent-v2` and `git push origin buildagent-v2`.

A tag that has been deployed is never moved; a fix gets the next number.

## Licence

Parts of the build agent setup are based on Microsoft's
[nav-arm-templates](https://github.com/microsoft/nav-arm-templates) (MIT). See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
