# pharma_b2b

B2B Pharmacy ordering platform

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Control plane

Since CHANGE #1761 the dev-queue control plane — `dev_commands`, the deploy lane,
journeys and QA — lives on the **medibo-dev** Supabase project
(ref `brorshtqrkyqqdhmhclw`). Production (ref `swojhmarmaijkshsbeih`) serves
customers only: it receives each change's final migration and the web deploy and
keeps the regression guard, the DB lane and the storage buckets. The runner fleet,
the merge worker and the app's Dev Queue screen (through a production-minted
`x-dev-console` ticket) all talk to medibo-dev.
