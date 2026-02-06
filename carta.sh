docker run --rm -it \
        -v "$PWD:/images" \
        -w "/images" \
        -p 3001:3001 \
        cartavis/carta:latest \
        --port 3001