# gcloud-os-images

## Index
- [Purpose](#purpose)
- [Repository Structure](#repository-structure)
- [How to Create a New OS Image](#how-to-create-a-new-os-image)
- [License](#license)

## Purpose
This repository provides a framework for building and managing custom OS images for Google Cloud Platform (GCP) using Packer. It enables automated, repeatable, and consistent creation of images for cloud infrastructure, supporting scalable and reliable deployments.

## Repository Structure
```
LICENSE
README.md
images/
  <image_name>/
    config/
    scripts/
shared_scripts/
```
- **images/**: Contains all OS image definitions and build scripts, organized by image type.
- **shared_scripts/**: Scripts commonly used during the creation of all OS images (e.g., system preparation, cleanup).

## How to Create a New OS Image

1. **Clone the repository:**
   ```bash
   git clone <repo-url>
   cd gcloud-os-images
   ```
2. **Install Packer:**
   Ensure [Packer](https://www.packer.io/) is installed on your system.

3. **Create a new image directory:**
   - Under `images/`, create a new directory for your OS image (e.g., `my_new_image`).
   - Inside this directory, add a `config/` folder for configuration files and a `scripts/` folder for provisioning scripts.
   - Place your Packer HCL file(s) in the new image directory.

4. **Configure variables:**
   Edit your Packer HCL file and set required variables such as `project_id`, `build_version`, and `zone`.

5. **Build the image:**
   ```bash
   packer init images/<image_name>/<packer_file>.pkr.hcl
   packer build -var 'project_id=<your-gcp-project>' -var 'build_version=<version>' images/<image_name>/<packer_file>.pkr.hcl
   ```
   Replace `<image_name>` and `<packer_file>` with your chosen names.

6. **Customize as needed:**
   - Shared scripts in `shared_scripts/` are typically used for common setup and cleanup tasks.
   - Image-specific scripts in each image's `scripts/` directory handle specialized configuration and provisioning.

## License
This project is licensed under the [Apache 2.0 License](./LICENSE).
