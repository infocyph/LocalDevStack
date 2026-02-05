LocalDevStack Documentation
==========================

LocalDevStack is a modular, Docker-based local development stack designed to replace traditional local bundles
(XAMPP/MAMP/LAMP) with a reproducible, profile-driven setup.

It is built around a small orchestrator (the ``server`` CLI + Compose profiles) and a set of purpose-built images
that work together (tools, HTTP, runner).

.. toctree::
   :maxdepth: 2
   :caption: Getting Started

   quickstart

.. toctree::
   :maxdepth: 2
   :caption: Concepts

   concepts/architecture
   concepts/profiles-and-env
   concepts/storage-layout

.. toctree::
   :maxdepth: 2
   :caption: Guides

   guides/domain-setup
   guides/tls-and-certificates
   guides/node-apps
   guides/secrets-sops-age
   guides/notifications
