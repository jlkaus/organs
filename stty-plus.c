#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
//#include <termios.h>

#include <stropts.h>
#include <asm/termios.h>



int main(int argc, char *argv[]) {
  // args:
  // 1 device file
  // 2 baudrate

  if(argc != 3) {
    printf("ERROR: Incorrect invocation\n");
    exit(1);
  }

  // Divide by 16 to get the real speed, I guess?
  int speed = atoi(argv[2]) / 16;
  
  int fd = open(argv[1], O_RDONLY);
  if(fd == -1) {
    perror("open");
    exit(1);
  }

  int rc = 0;
  
  /*
  struct termios tio;
  rc = tcgetattr(fd, &tio);
  if(rc != 0) {
    perror("tcgetattr");
    exit(1);
  }
  
  if(databits == 8) {
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;
  } else if(databits == 7) {
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS7;
  } else {
    // CS5 and CS6 are also supported, but I'm not going to bother for now.
    printf("ERROR: Unknown databits %d\n", databits);
    exit(1);
  }
  
  if(strcmp(parity, "none") == 0) {
    tio.c_cflag &= ~PARENB;
  } else if(strcmp(parity, "even") == 0) {
    tio.c_cflag |= PARENB;
    tio.c_cflag &= ~PARODD;
  } else if(strcmp(parity, "odd") == 0) {
    tio.c_cflag |= PARENB;
    tio.c_cflag |= PARODD;
  } else {
    printf("ERROR: Unknown parity %s\n", parity);
    exit(1);
  }

  if(stopbits == 2) {
    tio.c_cflag |= CSTOPB;
  } else if(stopbits == 1) {
    tio.c_cflag &= ~CSTOPB;
  } else {
    printf("ERROR: Unknown stopbits %d\n", stopbits);
    exit(1);
  }
  
  if(strcmp(handshake, "none") == 0) {
    tio.c_iflag &= ~IXON;
    tio.c_iflag &= ~IXOFF;
    tio.c_cflag &= ~CRTSCTS;
    
  } else {
    // Don't bother supporting handshakes at all, for now.
    printf("ERROR: Unknown handshake %s\n", handshake);
    exit(1);
  }
  
  rc = tcsetattr(fd, TCSANOW, &tio);
  if(rc != 0) {
    perror("tcsetattr");
    exit(1);
  }
  */  
  struct termios2 tio2;
  rc = ioctl(fd, TCGETS2, &tio2);
  if(rc != 0) {
    perror("ioctl TCGETS2");
    exit(1);
  }
  tio2.c_cflag &= ~CBAUD;
  tio2.c_cflag |= BOTHER;
  tio2.c_ispeed = speed;
  tio2.c_ospeed = speed;
  rc = ioctl(fd, TCSETS2, &tio2);
  if(rc != 0) {
    perror("ioctl TCSETS2");
    exit(1);
  }

  close(fd);

  return 0;
}
