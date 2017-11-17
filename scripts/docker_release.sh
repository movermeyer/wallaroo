#/bin/bash
set -e

if [[ "${TRAVIS_OS_NAME}" = "linux" && "${TRAVIS_BRANCH}" != "master" ]]
then
	## Sets Wallaroo Docker repo host to Bintray repo.
	wallaroo_docker_repo_host=wallaroo-labs-docker-wallaroolabs.bintray.io
	## Sets version variable to first version found in CHANGELOG
	version=`grep -Po '(?<=##\s\[).*(?=\])' CHANGELOG.md | head -1`
	## If version is unreleased, use commit as tag. Otherwise use version.
	if [ $version = "unreleased" ]

	then
		## Sets repo to dev for Wallaroo Docker image
		wallaroo_docker_image_repo=dev
		docker_image_tag=$(git describe --tags --always)
	else
		## Sets repo to first-install for Wallaroo Docker image
		wallaroo_docker_image_repo=first-install
		docker_image_tag=$version
	fi
	wallaroo_docker_image=wallaroo:$docker_image_tag
	wallaroo_docker_image_path=$wallaroo_docker_repo_host/$wallaroo_docker_image_repo/$wallaroo_docker_image
	## Conditional check for whether current image tag exists in repo, does not
	## re-upload image if so. Otherwise builds docker image and uploads to Bintray.
	returned_tag_name=$(curl -s "https://$wallaroo_docker_repo_host/v2/$wallaroo_docker_image_repo/wallaroo/tags/list" | jq ".tags" | grep -Po "(?<=\")$docker_image_tag(?=\")")
	if [[ $returned_tag_name == $docker_image_tag ]]
	then
		echo "Docker image: $wallaroo_docker_image_path already exists"
		exit 0
	else
		docker login -u wallaroolabs -p $DOCKER_PASSWORD $wallaroo_docker_repo_host
		make release-monhub-all
		docker build -t $wallaroo_docker_image_path .
		docker push $wallaroo_docker_image_path
		echo "Built and pushed image $wallaroo_docker_image_path successfully."
	fi
else
	exit 0
fi
