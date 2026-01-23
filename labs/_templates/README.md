# Lab Templates

This directory contains skeleton files for creating new labs. Copy the entire directory and customize for your specific use case.

## Quick Start

```bash
# 1. Copy template to your lab location
cp -r labs/_templates labs/<product>/lab-XX-your-topic

# 2. Rename the documentation file
mv labs/<product>/lab-XX-your-topic/lab-XX-template.md \
   labs/<product>/lab-XX-your-topic/lab-XX-your-topic.md

# 3. Update placeholders
# Search and replace: XX, TODO, CHANGEME, your-topic

# 4. Implement your lab logic

# 5. Test with a clean run
cd labs/<product>/lab-XX-your-topic
./scripts/stepN-cleanup.sh
./scripts/run-all.sh
```

## Directory Structure

```
_templates/
├── README.md              # This file
├── lab-XX-template.md     # Documentation skeleton
├── .env.example           # Environment variables template
├── scripts/
│   ├── common.sh          # Shared utilities
│   ├── step0-start.sh     # Infrastructure startup
│   ├── step1-load-data.sh # Data loading
│   ├── stepN-cleanup.sh   # Teardown
│   └── run-all.sh         # Orchestrator
├── sql/
│   └── .gitkeep           # Placeholder
├── conf/
│   └── .gitkeep           # Placeholder
└── results/
    └── .gitignore         # Ignore output files
```

## Customization Checklist

After copying, update these items:

- [ ] Rename `lab-XX-template.md` to match your lab directory name
- [ ] Update the title and goal in the documentation
- [ ] Fill in the "Tested Environment" section with actual versions
- [ ] Add your scenarios and steps
- [ ] Create SQL files in `sql/` directory
- [ ] Create config files in `conf/` directory (if needed)
- [ ] Update container names in scripts (replace `labXX-*`)
- [ ] Update network name in scripts (replace `labXX-net`)
- [ ] Adjust ports if needed to avoid conflicts
- [ ] Implement step scripts with actual logic
- [ ] Update `.env.example` with lab-specific variables

## Conventions

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for detailed guidelines on:

- Documentation standards
- Script conventions
- Infrastructure patterns
- Quality checklist
