package lab;

import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.ManyToOne;

@Entity
public class Book {
    @Id Integer id;
    String title;
    @ManyToOne(fetch = FetchType.LAZY)
    Author author;
}
