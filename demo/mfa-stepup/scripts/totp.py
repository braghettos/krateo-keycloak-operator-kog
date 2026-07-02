import sys, hmac, hashlib, struct, time
# Keycloak TOTP: HMAC-SHA1 over raw UTF-8 bytes of the stored secret, 30s, 6 digits
key = sys.argv[1].encode()
msg = struct.pack(">Q", int(time.time()) // 30)
h = hmac.new(key, msg, hashlib.sha1).digest()
o = h[-1] & 0x0f
print("%06d" % ((struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % 1000000))
